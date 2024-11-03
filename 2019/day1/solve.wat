(module
  ;; Importing WASI functions for file handling
  (import "wasi_snapshot_preview1" "fd_read" 
    (func $wasi_fd_read (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write" 
    (func $wasi_fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_filestat_get"
    (func $wasi_fd_filestat_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "path_open" 
    (func $wasi_path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $wasi_proc_exit (param i32)))

  ;; Declare a block of memory with 1 page (64 KiB), and export it so WASI can use it
  (memory $memory 1)
  (export "memory" (memory $memory))
  ;; Memory usage:
  ;; 0-7: temp IOVector used with WASI functions
  ;; 8-31: constant data (input filename)
  ;; 32-36: file descriptor (i32) for input file, once opened
  ;; 36-45: itoa constants 0-9
  ;; 46-47: newline character
  ;; 48-127: constant strings
  ;; 128-143: itoa output buffer
  ;; 256-8191: buffer for reading file contents
  ;; 8192-65535: working buffer

  ;; IOVector addresses
  ;; IOVector is a struct with two fields: a pointer to the buffer and the length of the buffer
  ;; This data structure is used for any WASI I/O that takes in a string
  (global $io_offset i32 (i32.const 0)) ;; IOVector offset (address of buffer)
  (global $io_len i32 (i32.const 4))    ;; IOVector length (size of buffer)

  ;; Data section with the filename
  (global $filename_offset i32 (i32.const 8)) ;; Offset for filename
  (global $filename_len i32 (i32.const 9)) ;; Filename length
  (data (i32.const 8) "input.txt\00") ;; Filename in memory
  
  ;; Constants for file descriptors
  (global $stdin i32 (i32.const 0))  ;; fd 0 is stdin
  (global $stdout i32 (i32.const 1))  ;; fd 1 is stdout
  (global $stderr i32 (i32.const 2))  ;; fd 2 is stderr
  (global $preopen i32 (i32.const 3))  ;; fd 3 is pre-opened directory (--dir option)

  (global $input_fd_offset i32 (i32.const 32)) ;; Offset for input file descriptor in memory

  ;; Debugging-related constants - println, println_number, die
  ;; Using some memory for a number-->digit ASCII lookup-table, and then the
  ;; space for writing the result of $itoa.
  (data (i32.const 36) "0123456789")
  (data (i32.const 46) "\n")
  
  ;; Debugging strings
  (data (i32.const 48) "Failed to read file\n")
  (global $failed_read_msg i32 (i32.const 48))
  (global $failed_read_msg_len i32 (i32.const 20))

  (data (i32.const 72) "File size is too large\n")
  (global $file_too_large_msg i32 (i32.const 72))
  (global $file_too_large_msg_len i32 (i32.const 23))

  (data (i32.const 96) "chomp\n")
  (data (i32.const 110) "atoi\n")
  (data (i32.const 116) "parse\n")

  ;; itoa output buffer
  (global $itoa_out_buf i32 (i32.const 128))

  ;; input file contents buffer
  (global $input_buf i32 (i32.const 256))
  (global $input_buf_len i32 (i32.const 7936))

  ;; input file parse position pointer
  (global $input_buf_ptr (mut i32) (i32.const 256))

  ;; working buffer
  (global $work_buf i32 (i32.const 8192))

  ;; println prints a string to stdout using WASI, adding a newline.
  ;; It takes the string's address and length as parameters.
  (func $println (param $strptr i32) (param $len i32)
    ;; Initialize IOVector for input string
    (i32.store (global.get $io_offset) (local.get $strptr))
    (i32.store (global.get $io_len) (local.get $len))

    (drop
      (call $wasi_fd_write
        (global.get $stdout)
        (global.get $io_offset)
        (i32.const 1)
        (global.get $io_len)
      )
    )
      
    ;; Initialize IOVector for newline
    (i32.store (global.get $io_offset) (i32.const 46))
    (i32.store (global.get $io_len) (i32.const 1))

    (drop
      (call $wasi_fd_write
        (global.get $stdout)
        (global.get $io_offset)
        (i32.const 1)
        (global.get $io_len)
      )
    )
  )

  ;; println_number prints a number as a string to stdout, adding a newline.
  ;; It takes the number as parameter.
  (func $println_number (param $num i32)
    (local $numtmp i32)
    (local $numlen i32)
    (local $writeidx i32)
    (local $digit i32)
    (local $dchar i32)

    ;; Count the number of characters in the output, save it in $numlen.
    (if
      (i32.lt_s (local.get $num) (i32.const 10))
      (then
        (local.set $numlen (i32.const 1))
      )
      (else
        (local.set $numlen (i32.const 0))
        (local.set $numtmp (local.get $num))
        (loop $countloop (block $breakcountloop
          (i32.eqz (local.get $numtmp))
          (br_if $breakcountloop)

          (local.set $numtmp (i32.div_u (local.get $numtmp) (i32.const 10)))
          (local.set $numlen (i32.add (local.get $numlen) (i32.const 1)))
          (br $countloop)
        ))
      )
    )
    
    ;; Now that we know the length of the output, we will start populating
    ;; digits into the buffer. E.g. suppose $numlen is 4:
    ;;
    ;;                     _  _  _  _
    ;;
    ;;                     ^        ^
    ;;  $itoa_out_buf -----|        |---- $writeidx
    ;;
    ;;
    ;; $writeidx starts by pointing to $itoa_out_buf+3 and decrements until
    ;; all the digits are populated.
    (local.set $writeidx
      (i32.sub
        (i32.add (global.get $itoa_out_buf) (local.get $numlen))
        (i32.const 1)))

    (loop $writeloop (block $breakwriteloop
      ;; digit <- $num % 10
      (local.set $digit (i32.rem_u (local.get $num) (i32.const 10)))
      ;; set the char value from the lookup table of digit chars
      (local.set $dchar (i32.load8_u offset=36 (local.get $digit)))

      ;; mem[writeidx] <- dchar
      (i32.store8 (local.get $writeidx) (local.get $dchar))

      ;; num <- num / 10
      (local.set $num (i32.div_u (local.get $num) (i32.const 10)))

      ;; If after writing a number we see we wrote to the first index in
      ;; the output buffer, we're done.
      (i32.eq (local.get $writeidx) (global.get $itoa_out_buf))
      br_if $breakwriteloop

      (local.set $writeidx (i32.sub (local.get $writeidx) (i32.const 1)))
      br $writeloop
    ))

    (call $println
      (global.get $itoa_out_buf)
      (local.get $numlen))
  )

  ;; Prints a message (address and len parameters) and exits the process
  ;; with return code 1.
  (func $die (param $strptr i32) (param $len i32)
    (call $println (local.get $strptr) (local.get $len))
    (call $wasi_proc_exit (i32.const 1))
  )

  ;; advances the input buffer pointer until it hits a number or the end of input
  ;; returns 0 if end of input was reached, and 1 otherwise
  (func $chomp (result i32)
    (local $char i32)
    (local $result i32)

    (local.set $result (i32.const 1))

    (block $LOOP_BREAK
      (loop $LOOP
        (local.set $char (i32.load8_u (global.get $input_buf_ptr)))

        ;; bail out if >= '0' and <= '9'
        (br_if $LOOP_BREAK
          (i32.and
            (i32.ge_u (local.get $char) (i32.const 48)) ;; ASCII value of '0'
            (i32.le_u (local.get $char) (i32.const 57)) ;; ASCII value of '9'
          )
        )

        ;; bail out if we've reached the end of the input ($input_buf + $input_buf_len)
        (if (i32.gt_u (global.get $input_buf_ptr) (i32.add (global.get $input_buf) (global.get $input_buf_len)))
          (then
            (local.set $result (i32.const 0))
            (br $LOOP_BREAK)
          )
        )

        ;; increment and loop
        (global.set $input_buf_ptr
          (i32.add
            (global.get $input_buf_ptr)
            (i32.const 1)
          )
        )

        (br $LOOP)
      )
    )

    (local.get $result)
  )

  ;; parses the string starting at $input_buf_ptr into a number, and advances the pointer
  (func $atoi (result i32)
    (local $char i32)
    (local $result i32)

    ;; loop over characters in the string until we hit something < '0' or > '9'.
    (block $LOOP_BREAK
      (loop $LOOP
        (local.set $char (i32.load8_u (global.get $input_buf_ptr)))

        ;; bail out if < '0'
        (br_if $LOOP_BREAK (i32.lt_u (local.get $char) (i32.const 48))) ;; ASCII value of '0'

        ;; bail out if > '9'
        (br_if $LOOP_BREAK (i32.gt_u (local.get $char) (i32.const 57))) ;; ASCII value of '9'

        ;; multiply current number by 10, and add new number
        (local.set $result
          (i32.add
            (i32.mul
              (local.get $result)
              (i32.const 10)
            )
            (i32.sub ;; (subtract 48, ASCII value of '0')
              (local.get $char)
              (i32.const 48)
            )
          )
        )

        ;; increment and loop
        (global.set $input_buf_ptr
          (i32.add
            (global.get $input_buf_ptr)
            (i32.const 1)
          )
        )

        (br $LOOP)
      )
    )

    (local.get $result)
  )

  ;; Parses the input buffer into the working buffer, returns the number of integers parsed
  (func $parse_input_to_working_buffer (param $file_size i32) (result i32)
    (local $i i32)
    (local $num i32)
    (local $ptr i32)
    (local $next_num i32)

    ;; Initialize the working buffer pointer
    (local.set $ptr (global.get $work_buf))

    (block $break_outer_loop
      (loop $outer_loop
        ;; Chomp any non-number input, return if end of input
        (if (i32.eqz (call $chomp))
          (then
            (br $break_outer_loop)
          )
        )

        ;; Break if we hit the end of the file
        (br_if $break_outer_loop
          (i32.ge_u
            (i32.sub (global.get $input_buf_ptr) (global.get $input_buf))
            (local.get $file_size)
          )
        )

        ;; Read a number from the input buffer
        (local.set $num (call $atoi (local.get $i)))

        ;; Store the number in the working buffer
        (i32.store (local.get $ptr) (local.get $num))
        (local.set $ptr (i32.add (local.get $ptr) (i32.const 4))) ;; Move to the next position in the working buffer

        ;; Increment return result
        (local.set $i (i32.add (local.get $i) (i32.const 1)))

        ;; Move to the next character in the input buffer
        (global.set $input_buf_ptr (i32.add (global.get $input_buf_ptr) (i32.const 1)))

        ;; Break if we hit the end of the input buffer
        (br_if $break_outer_loop (i32.gt_u (global.get $input_buf_ptr) (i32.const 8192)))

        (br $outer_loop)
      )

    )

    ;; Return the number of integers parsed
    (local.get $i)
  )

  (func $get_answer (param $input_len i32) (result i32)
    (local $ptr i32)
    (local $answer i32)

    (local.set $ptr (global.get $work_buf))
    
    ;; Loop over the working buffer and, for every integer, add it to the answer
    ;; after dividing it by 3, rounding down, then subtracting 2:
    (local.set $answer (i32.const 0))
    (block $break_loop
      (loop $LOOP
        (local.set $answer
          (i32.add
            (local.get $answer)
            (i32.sub
              (i32.div_u (i32.load (local.get $ptr)) (i32.const 3))
              (i32.const 2)
            )
          )
        )

        (local.set $ptr (i32.add (local.get $ptr) (i32.const 4)))

        (i32.eq (local.get $ptr) (i32.add (global.get $work_buf) (i32.mul (local.get $input_len) (i32.const 4))))
        (br_if $break_loop)

        (br $LOOP)
      )
    )

    (local.get $answer)
  )

  (func $main
    ;; Local variables
    (local $fd i32)          ;; To store file descriptor
    (local $result i32)      ;; To store the result of wasi calls
    (local $file_size i32)   ;; To store the file size
    (local $input_len i32)   ;; To store the amount of numbers read from input

    ;; Open the file. Store result of wasi_path_open in $result
    (local.set $result
      (call $wasi_path_open
        (global.get $preopen)          ;; dirfd = 3 (pre-opened directory)
        (i32.const 0)                  ;; lookupflags = 0
        (global.get $filename_offset)  ;; offset to file name in memory (file.txt)
        (global.get $filename_len)     ;; file name length (8)
        (i32.const 0)                  ;; oflags = 0
        (i64.const 1)                  ;; fs_rights_base (read rights)
        (i64.const 0)                  ;; fs_rights_inheriting (inheriting rights)
        (i32.const 0)                  ;; fd_flags = 0
        (global.get $input_fd_offset)  ;; Output pointer for the file descriptor
      )
    )

    (if ;; Check if open was successful
      (i32.ne (local.get $result) (i32.const 0))
      (then
        (call $die
          (global.get $failed_read_msg)
          (global.get $failed_read_msg_len)
        )
      )
    )

    ;; Load the file descriptor from memory
    (local.set $fd (i32.load (global.get $input_fd_offset)))

    ;; Get the filestat for the file size
    (local.set $result
      (call $wasi_fd_filestat_get
        (local.get $fd) ;; file fd
        (global.get $input_buf) ;; where to store the results
      )
    )

    (if ;; Check if stat was successful
      (i32.ne (local.get $result) (i32.const 0))
      (then
        (call $die
          (global.get $failed_read_msg)
          (global.get $failed_read_msg_len)
        )
      )
    )

    ;; Get the file size from the filestat (i64 at offset 32)
    (local.set $file_size
      (i32.wrap_i64
        (i64.load (i32.add (global.get $input_buf) (i32.const 32)))
      )
    )

    ;; Exit with an error if the file is too large for the input buffer
    (if
      (i32.gt_u (local.get $file_size) (global.get $input_buf_len))
      (then
        (call $die
          (global.get $file_too_large_msg)
          (global.get $file_too_large_msg_len)
        )
      )
    )

    ;; prepare our IOVector to point to the buffer
    (i32.store (global.get $io_offset) (global.get $input_buf))
    (i32.store (global.get $io_len) (global.get $input_buf_len))

    ;; Read from file and drop result (0 or errno)
    (local.set $result
      (call $wasi_fd_read
        (local.get $fd) ;; file fd
        (global.get $io_offset)
        (i32.const 1) ;; Number of IOVectors (1)
        (i32.const 4) ;; where to stuff the number of bytes read
      )
    )

    (if ;; Check if read was successful
      (i32.ne (local.get $result) (i32.const 0))
      (then
        (call $die
          (global.get $failed_read_msg)
          (global.get $failed_read_msg_len)
        )
      )
    )

    (local.set $input_len
      (call $parse_input_to_working_buffer (local.get $file_size))
    )

    (call $println_number (call $get_answer (local.get $input_len)))

    ;; Write to stdout and drop result (0 or errno)
    (drop
      (call $wasi_fd_write
        (global.get $stdout) ;; stdout fd
        (i32.const 0) (i32.const 1) ;; 1 IOVector at address 0
        (i32.const 4) ;; where to stuff the number of bytes read
      )
    )
  )

  ;; Export the main function as "_start" so it is run automatically
  (export "_start" (func $main))
)
