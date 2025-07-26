@
@ ISR Master Handler for ZigGBA
@ Based on libtonc's isr_master.s but adapted for Zig
@
@ This file should be compiled for ARM mode, not Thumb
@

.section .iwram, "ax", %progbits
.align 2
.global isr_master
.type isr_master, %function

@ External reference to the ISR table
.extern isr_table

@ Register usage:
@ r0 : &REG_IE
@ r1 : isr_table / isr
@ r2 : IF & IE (active interrupts)
@ r3 : tmp
@ ip : (IF,IE)

isr_master:
    @ Read IF/IE
    mov     r0, #0x04000000
    ldr     ip, [r0, #0x200]!    @ Load REG_IE
    ldr     r3, [r0, #2]         @ Load REG_IF
    and     r2, ip, r3           @ irq = IE & IF

    @ Acknowledge irq in IF and for BIOS
    strh    r2, [r0, #2]         @ REG_IF = irq
    ldr     r3, [r0, #-0x208]    @ Load REG_IFBIOS
    orr     r3, r3, r2           @ REG_IFBIOS |= irq
    str     r3, [r0, #-0x208]    @ Store back

    @ Search for irq in isr_table
    ldr     r1, =isr_table

.Lirq_search:
    ldr     r3, [r1], #8         @ Load flag, advance to next entry
    tst     r3, r2               @ Test if this flag matches active irq
    bne     .Lpost_search        @ Found one, break off search
    cmp     r3, #0               @ Check if end of table
    bne     .Lirq_search         @ Not here; try next irq

    @ Search over: return if no isr, otherwise continue
.Lpost_search:
    ldrne   r1, [r1, #-4]        @ isr = isr_table[ii-1].isr
    cmpne   r1, #0               @ Check if handler exists
    bxeq    lr                   @ If no isr: quit

    @ --- If we're here, we have an isr ---

    ldr     r3, [r0, #8]         @ Read IME
    strb    r0, [r0, #8]         @ Clear IME
    bic     r2, ip, r2           @ Clear current irq in IE
    strh    r2, [r0]             @ Store back

    mrs     r2, spsr
    stmfd   sp!, {r2-r3, ip, lr} @ sprs, IME, (IE,IF), lr_irq

    @ Set mode to usr
    mrs     r3, cpsr
    bic     r3, r3, #0xDF
    orr     r3, r3, #0x1F
    msr     cpsr, r3

    @ Call isr
    stmfd   sp!, {r0,lr}         @ &REG_IE, lr_sys
    mov     lr, pc
    bx      r1                   @ Call the handler
    ldmfd   sp!, {r0,lr}         @ &REG_IE, lr_sys

    @ --- Unwind ---
    strb    r0, [r0, #8]         @ Clear IME again (safety)

    @ Reset mode to irq
    mrs     r3, cpsr
    bic     r3, r3, #0xDF
    orr     r3, r3, #0x92
    msr     cpsr, r3

    ldmfd   sp!, {r2-r3, ip, lr} @ sprs, IME, (IE,IF), lr_irq
    msr     spsr, r2             @ Restore spsr
    strh    ip, [r0]             @ Restore IE
    str     r3, [r0, #8]         @ Restore IME

    bx      lr

.size isr_master, .-isr_master

# Storage for ISR table (14 entries x 8 bytes)
.section .sbss, "aw", %nobits
.align 2
.global isr_table
isr_table:
    .space 112
