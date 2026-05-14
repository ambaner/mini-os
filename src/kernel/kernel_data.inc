; =============================================================================
; DATA
; =============================================================================
msg_syscall     db 'Syscall handler (INT 0x80)', 0
msg_fs          db 'FS.BIN loaded', 0
msg_fs_init     db 'Filesystem (INT 0x81)', 0
msg_fs_find     db 'FS.BIN not found', 0
msg_fs_load     db 'FS.BIN load', 0
msg_fs_initf    db 'FS.BIN init', 0
msg_shell       db 'SHELL.BIN loaded', 0
msg_sh_find     db 'SHELL.BIN not found', 0
msg_sh_load     db 'SHELL.BIN load', 0
msg_mm          db 'MM.BIN loaded', 0
msg_mm_init     db 'Memory manager (INT 0x82)', 0
msg_mm_find     db 'MM.BIN not found', 0
msg_mm_load     db 'MM.BIN load', 0
msg_mm_initf    db 'MM.BIN init', 0
msg_anykey      db 13, 10, '  Press any key...', 0

; 11-byte "8.3" filenames for directory lookup
fname_fs        db 'FS      BIN'
fname_fsd       db 'FSD     BIN'
fname_mm        db 'MM      BIN'
fname_mmd       db 'MMD     BIN'
fname_shell     db 'SHELL   BIN'
fname_shelld    db 'SHELLD  BIN'

; --- Disk Address Packet (DAP) for INT 13h AH=42h ----------------------------
; Used by both load_mnex (during init) and SYS_READ_SECTOR (during runtime).
; These never run concurrently, so sharing one DAP is safe.
dap:
    db 0x10, 0
dap_sectors:
    dw 0
dap_buffer:
    dw 0, 0
dap_lba:
    dd 0, 0
