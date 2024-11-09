(module
  ;; Importing WASI functions for I/O and filesystem operations.
  ;; See https://github.com/WebAssembly/WASI/blob/main/legacy/preview1/docs.md
  ;;
  ;; These functions store their result at the pointer given as the last parameter, and
  ;; return an error code (errno) - 0 if successful, non-zero if an error occurred.
  ;;
  ;; Some of them also take a pointer to an IOVector array as input.
  ;; A single IOVector is an 8-byte struct with two fields describing a buffer to use for
  ;; the I/O operation:
  ;; - i32: pointer to the buffer
  ;; - i32: length of the buffer
  ;;
  ;; Note that file descriptors must first be opened with `wasi_path_open`, unless they're one of
  ;; the preopened descriptors:
  ;; - 0: stdin
  ;; - 1: stdout
  ;; - 2: stderr
  ;; - ?: preopened directory (--dir option) - usually 3, but discover with get_first_good_dir_fd
  ;;
  (import "wasi_snapshot_preview1" "fd_read" 
    (func $wasi_fd_read ;; Reads bytes from file descriptor to IOVectors
      (param
        i32 ;; file_descriptor - Opened file descriptor to read from
        i32 ;; *iovecs (struct: i32, i32) - IOVector array pointer
        i32 ;; iovecs_len - Length of the IOVector array
        i32 ;; *nwritten - Pointer to an memory address to store the number of bytes read
      )
      (result i32) ;; errno - Error code, 0 if successful, non-zero if an error occurred
    )
  )
  (import "wasi_snapshot_preview1" "fd_write" 
    (func $wasi_fd_write ;; Writes bytes from IOVectors to file descriptor
      (param
        i32 ;; file_descriptor - Opened file descriptor to write to
        i32 ;; *iovecs (struct: i32, i32) - IOVector array pointer 
        i32 ;; iovecs_len - Length of the IOVector array
        i32 ;; *nwritten (i32) - Pointer to an memory address to store the number of bytes read
      )
      (result i32) ;; errno - Error code, 0 if successful, non-zero if an error occurred
    )
  )
  (import "wasi_snapshot_preview1" "fd_prestat_get"
    (func $wasi_fd_prestat_get ;; Get info for preopened fd (useful to tell if fd is valid)
      (param
        i32 ;; file_descriptor - Opened file descriptor to get prestat for
        i32 ;; *prestat (struct: 8 bytes) - Pointer to a buffer to store the prestat info
      )
      (result i32) ;; errno - Error code, 0 if successful, non-zero if an error occurred
    )
  )
  (import "wasi_snapshot_preview1" "fd_filestat_get"
    (func $wasi_fd_filestat_get ;; Get attributes for file at fd (useful to get file size)
      (param
        i32 ;; file_descriptor - Opened file descriptor to get filestat for
        i32 ;; *filestat (struct: 64 bytes) - Pointer to a buffer to store the filestat info
        ;; filestat struct format:
        ;; (see https://github.com/WebAssembly/WASI/blob/main/legacy/preview1/docs.md#filestat)
        ;;
        ;; 0: device - Device ID of device containing the file
        ;; 8: inode - File serial number
        ;; 16: filetype - File type
        ;; 24: linkcount - Number of hard links to the file
        ;; 32: filesize
        ;;  - For regular files, the file size in bytes
        ;;  - For symbolic links, the size in bytes of the pathname contained in the symbolic link
        ;; 40: a_time -  Last data access timestamp
        ;; 48: m_time - Last data modification timestamp
        ;; 56: c_time - Last file status change timestamp
      )
      (result i32) ;; errno - Error code, 0 if successful, non-zero if an error occurred
    )
  )
  (import "wasi_snapshot_preview1" "path_open"
    (func $wasi_path_open ;; Open a file or directory at a relative path from a preopened directory
      (param
        i32 ;; dirfd - Preopened directory file descriptor to open the file relative to
        i32 ;; lookupflags - Flags determining how the path is resolved
        i32 ;; *path - Pointer to the path string in memory
        i32 ;; path_len - Length of the path string
        i32 ;; oflags - Flags determining how to open the file
        i64 ;; fs_rights_base - Rights of the file descriptor itself
        i64 ;; fs_rights_inheriting - Rights of file descriptors derived from the file descriptor
        i32 ;; fd_flags - Flags for the new file descriptor
        i32 ;; *opened_fd (i32) - Pointer to a buffer to store the opened file descriptor
      )
      (result i32) ;; errno - Error code, 0 if successful, non-zero if an error occurred
    )
  )
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $wasi_proc_exit ;; Exit the process with the given exit code
      (param i32) ;; exit_code - Exit code to return to the operating system (0 for success)
    )
  )

  ;; File descriptor constants
  (global $stdin i32 (i32.const 0))  ;; fd 0 is stdin
  (global $stdout i32 (i32.const 1))  ;; fd 1 is stdout
  (global $stderr i32 (i32.const 2))  ;; fd 2 is stderr

  ;; Declare a block of memory with 4 pages (64 KiB each * 4 = 256 KiB total)
  (memory $memory 4)
  ;; Export the memory so WASI can use it
  (export "memory" (memory $memory))

  ;; Memory usage:
  ;; 0 (i32, i32):  temp IOVector used with WASI functions
  ;; 16 (i32):      file descriptor for input file, once opened
  ;; 32-41:         $itoa lookup table 0-9
  ;; 42:            newline character
  ;; 64-99:         $itoa output buffer
  ;; 100-65535:     constants
  ;; 65536-131071:  input buffer for results of I/O operations
  ;; 131072-262143: working buffer

  ;; IOVector, used for WASI I/O (see above for full description)
  (global $iovec_ptr_ptr i32 (i32.const 0)) ;; i32: buffer pointer
  (global $iovec_len_ptr i32 (i32.const 4))    ;; i32: buffer length in bytes

  ;; file descriptor for input file, once opened
  (global $input_fd_ptr i32 (i32.const 16))

  ;; number-->digit ASCII lookup-table for $itoa.
  (data (i32.const 32) "0123456789")

  ;; newline character
  (data (i32.const 42) "\n")
  (global $newline i32 (i32.const 42))

  ;; $itoa output buffer
  (global $itoa_out_buf i32 (i32.const 64))

  ;; constant string - Input filename
  (data (i32.const 100) "input.txt\00")
  (global $input_filename_ptr i32 (i32.const 100))
  (global $input_filename_len i32 (i32.const 9))

  ;; constant string - File read error message
  (data (i32.const 200) "Invalid preopened directory\n")
  (global $invalid_preopen_msg i32 (i32.const 200))
  (global $invalid_preopen_msg_len i32 (i32.const 28))

  ;; constant string - File read error message
  (data (i32.const 300) "Failed to read file\n")
  (global $failed_read_msg i32 (i32.const 300))
  (global $failed_read_msg_len i32 (i32.const 20))

  ;; constant string - File too large error message
  (data (i32.const 400) "File size is too large\n")
  (global $file_too_large_msg i32 (i32.const 400))
  (global $file_too_large_msg_len i32 (i32.const 23))

  ;; input file contents buffer
  (global $input_buf i32 (i32.const 65536))
  (global $input_buf_len i32 (i32.const 65535))

  ;; input file parse position pointer
  (global $input_buf_ptr (mut i32) (i32.const 65536))

  ;; working buffer
  (global $work_buf i32 (i32.const 131072))

  (func $get_first_good_dir_fd (param $fd i32) (result i32)
    (local $dirfd i32)
    (local $errno i32)

    ;; Start with the lowest fd after stdin, stdout, and stderr.
    (local.set $dirfd (i32.const 3))

    (block ;; label = @1
      (block ;; label = @2
        (loop $loop ;; label = @3
          (call $wasi_fd_prestat_get
            (local.get $dirfd)
            (i32.const 0)
          )

          ;; If errno is 0, we found a good dirfd. Break the loop.
          (br_if 2 (;@1;) (i32.eq (local.tee $errno) (i32.const 0)))

          ;; If errno is 8, we encountered `badf`. Return 8 indicating failure.
          (br_if 1 (;@2;) (i32.eq (local.get $dirfd) (i32.const 10)))

          ;; Increment dirfd.
          (local.set $dirfd (i32.add (local.get $dirfd) (i32.const 1)))

          (br $loop)
        )
      )

      (return (i32.const 8))
    )

    (i32.store (local.get $fd) (local.get $dirfd))
    i32.const 0
  )

  ;; println prints a string to stdout using WASI, adding a newline.
  ;; It takes the string's address and length as parameters.
  (func $println (param $strptr i32) (param $len i32)
    ;; Initialize IOVector for input string
    (i32.store (global.get $iovec_ptr_ptr) (local.get $strptr))
    (i32.store (global.get $iovec_len_ptr) (local.get $len))

    (drop
      (call $wasi_fd_write
        (global.get $stdout)
        (global.get $iovec_ptr_ptr)
        (i32.const 1)
        (global.get $iovec_len_ptr)
      )
    )
      
    ;; Initialize IOVector for newline
    (i32.store (global.get $iovec_ptr_ptr) (global.get $newline))
    (i32.store (global.get $iovec_len_ptr) (i32.const 1))

    (drop
      (call $wasi_fd_write
        (global.get $stdout)
        (global.get $iovec_ptr_ptr)
        (i32.const 1)
        (global.get $iovec_len_ptr)
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
      (local.set $dchar (i32.load8_u offset=32 (local.get $digit)))

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
        (br_if $break_outer_loop
          (i32.ge_u
            (global.get $input_buf_ptr)
            (i32.add (global.get $input_buf) (global.get $input_buf_len))
          )
        )

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
    (local $dirfd i32)       ;; To store the directory file descriptor
    (local $fd i32)          ;; To store file descriptor
    (local $errno i32)      ;; To store the result of wasi calls
    (local $file_size i32)   ;; To store the file size
    (local $input_len i32)   ;; To store the amount of numbers read from input

    ;; Get the first good directory file descriptor (preopened with --dir)
    (local.set $errno (call $get_first_good_dir_fd (global.get $input_buf)))

    (if ;; Check if open was successful
      (i32.ne (local.get $errno) (i32.const 0))
      (then
        (call $die
          (global.get $invalid_preopen_msg)
          (global.get $invalid_preopen_msg_len)
        )
      )
    )

    (local.set $dirfd (i32.load (global.get $input_buf)))

    ;; Open the file. Store result of wasi_path_open in $errno
    (local.set $errno
      (call $wasi_path_open
        (local.get $dirfd)               ;; pre-opened directory fd
        (i32.const 0)                    ;; lookupflags = 0
        (global.get $input_filename_ptr) ;; offset to file name in memory (file.txt)
        (global.get $input_filename_len)       ;; file name length (8)
        (i32.const 0)                    ;; oflags = 0
        (i64.const 1)                    ;; fs_rights_base (read rights)
        (i64.const 0)                    ;; fs_rights_inheriting (inheriting rights)
        (i32.const 0)                    ;; fd_flags = 0
        (global.get $input_fd_ptr)    ;; Output pointer for the file descriptor
      )
    )

    (if ;; Check if open was successful
      (i32.ne (local.get $errno) (i32.const 0))
      (then
        (call $die
          (global.get $failed_read_msg)
          (global.get $failed_read_msg_len)
        )
      )
    )

    ;; Load the file descriptor from memory
    (local.set $fd (i32.load (global.get $input_fd_ptr)))

    ;; Get the filestat for the file size
    (local.set $errno
      (call $wasi_fd_filestat_get
        (local.get $fd) ;; file fd
        (global.get $input_buf) ;; where to store the results
      )
    )

    (if ;; Check if stat was successful
      (i32.ne (local.get $errno) (i32.const 0))
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
    (i32.store (global.get $iovec_ptr_ptr) (global.get $input_buf))
    (i32.store (global.get $iovec_len_ptr) (global.get $input_buf_len))

    ;; Read from file and drop result (0 or errno)
    (local.set $errno
      (call $wasi_fd_read
        (local.get $fd) ;; file fd
        (global.get $iovec_ptr_ptr)
        (i32.const 1) ;; Number of IOVectors (1)
        (i32.const 4) ;; where to stuff the number of bytes read
      )
    )

    (if ;; Check if read was successful
      (i32.ne (local.get $errno) (i32.const 0))
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
