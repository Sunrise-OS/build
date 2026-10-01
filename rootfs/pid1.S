// Minimal Darwin ARM64 PID 1: no libc, dyld, or Linux syscall numbers.
.section __TEXT,__const
console_path: .asciz "/dev/console"
message: .ascii "XNU bring-up PID 1: userspace reached (pid=1)\n"
message_end:
.set message_length, message_end-message
.text
.globl _start
.p2align 2
_start:
    bti c
    mov x16, #20 // getpid
    svc #0x80
    cmp x0, #1
    b.ne failed
    // PID 1 starts without inherited stdio; XNU has already mounted devfs.
    adrp x0, console_path@PAGE
    add x0, x0, console_path@PAGEOFF
    mov x1, #1 // O_WRONLY
    mov x2, #0
    mov x16, #5 // open
    svc #0x80
    b.cs failed
    mov x19, x0
    mov x0, x19
    adrp x1, message@PAGE
    add x1, x1, message@PAGEOFF
    mov x2, #message_length
    mov x16, #4 // write
    svc #0x80
    b.cs failed
    // Sleep with select(0, NULL, NULL, NULL, &timeout). Never exit PID 1.
    sub sp, sp, #16
sleep_loop:
    mov x9, #60
    str x9, [sp]
    str xzr, [sp, #8]
    mov x0, #0
    mov x1, #0
    mov x2, #0
    mov x3, #0
    mov x4, sp
    mov x16, #93 // select
    svc #0x80
    b sleep_loop
failed:
    // If execution reaches here, trigger an unmistakable user exception.
    brk #0x101
    b failed
