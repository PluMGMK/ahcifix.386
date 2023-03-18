PAGE 58,132
;******************************************************************************
TITLE AHCIfix.asm -
;******************************************************************************
;
;   (C) Copyright MICROSOFT Corp., 1988-1990, PluMGMK 2023
;
;   Title:	AHCIfix.asm -
;
;   Version:	1.00
;
;   Date:	17-Mar-2023
;
;   Author:	PluMGMK
;
;------------------------------------------------------------------------------
;
;   Change log:
;
;      DATE	REV		    DESCRIPTION
;   ----------- ---- ----------------------------------------------------------
;   17-Mar-2023 PluM
;
;==============================================================================
	.386p

;******************************************************************************
;			      I N C L U D E S
;******************************************************************************

.XLIST
	INCLUDE VMM.INC
	INCLUDE Debug.INC
.LIST

;******************************************************************************
;		 V I R T U A L	 D E V I C E   D E C L A R A T I O N
;******************************************************************************

; SCSI FastDisk - hopefully nobody has both SCSI and AHCI in the same machine...
Declare_Virtual_Device AHCIfix, 1, 0, AHCIfix_Control, SCSIFD_Device_ID, BiosHook_Init_Order

VxD_DATA_SEG

; Retpoint of dodgy int 4Bh call:
; Our hook traps any int 4Bh that would return here.
dodgy_int4B_retvec label dword
dodgy_int4B_retoff	dw ?
dodgy_int4B_retseg	dw ?

callback_vector label dword
callback_off	dw ?
callback_seg	dw ?

; A little scratchpad to store the first 6Ch bytes of the EBDA while the silly
; firmware is allowing it to be overwritten by an EDD structure. *facepalm*
; In theory, the int 4Bh call may overwrite up to 98h bytes of the EBDA, but
; from 6Ch we have disk status stuff, which the firmware itself should update
; anyway at the end of the disk transfer operation (i.e. after int 4Bh).
scratchpad	dd (6Ch SHR 2) dup (0)
; set to true to indicate callback should restore EBDA from scratchpad
restore_spad	db False

VxD_DATA_ENDS

DEBUG_FIRMWARE_CS equ False

DD_Struc struc
DD_size		dd ?
DD_offset	dd ?
DD_segment	dw ?
DD_bufid	dw ?
DD_physaddx	dd ?
DD_Struc ends

EDD_Struc struc
EDD_size	dd ?
EDD_offset	dd ?
EDD_segment	dd ?
EDD_numavail	dw ?
EDD_numused	dw ?
EDD_physaddx	dd ?
EDD_physsize	dd ?
; And there can be more regions
EDD_Struc ends

VxD_ICODE_SEG

;******************************************************************************
;
;   AHCIfix_Device_Init
;
;   DESCRIPTION:
;
;   ENTRY:
;	EBX = SYS VM's handle
;	EDX = Reference data from real mode init portion
;		(i.e. dodgy int 4Bh retpoint)
;
;   EXIT:	    Carry clear if no error
;
;   USES:	    Nothing
;
;   ASSUMES:
;
;==============================================================================

BeginProc AHCIfix_Device_Init

	mov	[dodgy_int4B_retvec], edx

	mov	esi, OFFSET32 Restore_ES_DS
	xor	edx, edx
	VMMcall Allocate_V86_Call_Back
	jc	@F
	mov	[callback_vector], eax

	mov	esi, OFFSET32 VDS_Hook
	mov	eax, 4Bh
	VMMcall Hook_V86_Int_Chain

@@:
	ret

EndProc AHCIfix_Device_Init

VxD_ICODE_ENDS

VxD_LOCKED_CODE_SEG

;******************************************************************************
;
;   AHCIfix_Control
;
;   DESCRIPTION:    dispatch control messages to the correct handlers
;
;   ENTRY:
;
;   EXIT:	    Carry clear if no error
;
;   USES:
;
;==============================================================================

BeginProc AHCIfix_Control

	Control_Dispatch Device_Init, AHCIfix_Device_Init
	clc
	ret

EndProc AHCIfix_Control


BeginProc VDS_Hook
	push	eax

	mov	eax,[dodgy_int4B_retvec]
	ror	eax,10h
	cmp	ax,[ebp.Client_CS]
	jne	@F
if DEBUG_FIRMWARE_CS
	int	3
endif

	shr	eax,10h
	cmp	eax,[ebp.Client_EIP]
	jne	@F

	mov	eax,[ebp.Client_EAX]
	cmp	ax, 8103h	; LOCK DMA REGION
	je	@@islock

	cmp	ax, 8106h	; SCATTER/GATHER UNLOCK DMA REGION
	je	@@isunlock

	cmp	ax, 8104h	; UNLOCK DMA REGION
	jne	@F

	cmp	[scratchpad], 0	; is the first dword of the scratchpad zero?
	jz	@@isunlock
	mov	[restore_spad], True

@@isunlock:
	mov	ax,[ebp.Client_DS]
	cmp	[ebp.Client_ES],ax
	je	@F	; if DS == ES, we're OK

	push	ecx
	movzx	eax, [ebp.Client_ES]
	shl	eax, 4
	movzx	ecx, [ebp.Client_DI]
	add	eax, ecx
	pop	ecx

	Begin_Touch_1st_Meg
	; Is the physical address set to zero?
	cmp	dword ptr [eax.DD_physaddx], 0
	setz	al
	End_Touch_1st_Meg	; not sure if this messes with ZF...
	test	al,al
	jz	@F		; OK, not dodgy!

	; swap ES/DX
	mov	ax,[ebp.Client_DS]
	xchg	[ebp.Client_ES],ax
	mov	[ebp.Client_DS],ax

	; and set the return point to our callback, to swap them back afterwards
	movzx	eax,[callback_off]
	mov	[ebp.Client_EIP],eax
	mov	ax,[callback_seg]
	mov	[ebp.Client_CS],ax

@@:
	pop	eax
	stc	; pass through to next vector
	ret

@@islock:
	push	edi

	movzx	eax,[ebp.Client_ES]
	shl	eax,4
	movzx	edi,word ptr [ebp.Client_EDI]
	add	edi,eax

	Begin_Touch_1st_Meg
	mov	ax,[edi.DD_segment]
	cmp	ax,word ptr ds:[40Eh]		; Is it locking in the EBDA?
	jne	@@done_lock_sg

	cmp	[edi.DD_offset],size scratchpad	; beginning of EBDA?
	jnb	@@done_lock_sg

	; OK, firmware bug #2!
	; Need to back up what's in the EBDA and restore it later...
	push	ecx
	push	esi

	mov	ecx,size scratchpad SHR 2
	movzx	esi,word ptr ds:[40Eh]
	shl	esi,4
	lea	edi,scratchpad
	cld
	rep	movsd

	pop	esi
	pop	ecx

@@done_lock_sg:
	End_Touch_1st_Meg
	pop	edi
	jmp	@B
EndProc VDS_Hook

BeginProc Restore_ES_DS
	push	eax

	; swap ES/DX
	mov	ax,[ebp.Client_DS]
	xchg	[ebp.Client_ES],ax
	mov	[ebp.Client_DS],ax

	; restore the retpoint
	movzx	eax,[dodgy_int4B_retoff]
	mov	[ebp.Client_EIP],eax
	mov	ax,[dodgy_int4B_retseg]
	mov	[ebp.Client_CS],ax

	cmp	[restore_spad], True
	jne	@F

	; Restore what we backed up before...
	mov	[restore_spad], False

	push	ecx
	push	esi
	push	edi

	Begin_Touch_1st_Meg
	mov	ecx,size scratchpad SHR 2
	movzx	edi,word ptr ds:[40Eh]	; EBDA
	shl	edi,4
	lea	esi,scratchpad
	cld
	rep	movsd
	End_Touch_1st_Meg

	; clear the scratchpad
	mov	ecx,size scratchpad SHR 2
	lea	edi,scratchpad
	xor	eax,eax
	rep	stosd

	pop	edi
	pop	esi
	pop	ecx

@@:
	pop	eax
	ret
EndProc Restore_ES_DS

VxD_LOCKED_CODE_ENDS


VxD_CODE_SEG

BeginDoc
;******************************************************************************
;
;   AHCIfix_Get_Version
;
;   DESCRIPTION:    Get AHCIfix device version
;
;   ENTRY:
;
;   EXIT:	    IF Carry clear
;			EAX is version
;		    ELSE AHCIfix device not installed
;
;   USES:	FLAGS,EAX
;
;==============================================================================
EndDoc

BeginProc AHCIfix_Get_Version, SERVICE

	mov	eax, 100h
	clc
	ret

EndProc AHCIfix_Get_Version


VxD_CODE_ENDS


;******************************************************************************
;******************************************************************************
;
; Real mode initialization code
;
;******************************************************************************

VxD_REAL_INIT_SEG

orig_int13	label dword
orig_int13_off	dw ?
orig_int13_seg	dw ?

orig_int4B	label dword
orig_int4B_off	dw ?
orig_int4B_seg	dw ?

dodgy_int4B_retpoint	dd 0

rminit_scratchpad	EDD_Struc <0>

orig_vds_flags	db ?

;   ENTRY:
;       CS=DS=ES
;       AX = Win386 version number (requires 3.10)
;	SI = Environment segment
BeginProc AHCIfix_init

	test	bx, Duplicate_Device_ID
	jnz	no_AHCIfix_fnd	    ; don't load if an AHCIfix device has already
				    ; loaded!

	; Use int 2Fh to get the original int 13h vector.
	; To do this, we (annoyingly) have to set it to something fake
	; before changing it back...
	mov	ah, 13h
	lea	bx, tmp_int13
	lea	dx, tmp_int13
	cli	; don't allow anything to accidentally call int 13h while we're doing this!
	int	2Fh
	; save the vector
	mov	cs:[orig_int13_off], bx
	mov	cs:[orig_int13_seg], es
	; restore original vectors (and hence our ES/DS!)
	int	2Fh
	sti

	; now make sure that int 2Fh AH=13h actually did anything...
	mov	ax, cs
	cmp	[orig_int13_seg], ax
	jne	@F

	; OK, that hook did nothing, fall back to int 21h AH=35h...
	mov	ax, 3513h	; get int 13h vector
	int	21h
	mov	[orig_int13_off], bx
	mov	[orig_int13_seg], es

@@:
	; Now hook int 4Bh and start accessing hard drives...
	mov	ax, 354Bh	; get int 4Bh vector
	int	21h
	mov	[orig_int4B_off], bx
	mov	[orig_int4B_seg], es
	mov	ax, 254Bh
	lea	dx, tmp_int4B
	int	21h

	mov	ax, 40h
	mov	es, ax		; ES = BIOS data area
	; check if VDS is supported and lie if it isn't
	mov	al, es:[7Bh]
	mov	[orig_vds_flags],al
	bts	al, 5		; pretend VDS is supported even if it isn't
	mov	es:[7Bh], al

	; get number of hard drives
	movzx	cx, byte ptr es:[75h]
	mov	dx, 80h		; first HDD
@@:
	mov	ax, 201h	; read one sector
	push	cx
	xor	cx,cx		; first sector
	cli
	pushf
	call	[orig_int13]
	sti
	inc	dl		; next drive
	cmp	[dodgy_int4B_retpoint],0
	pop	cx
	loopz	@B		; try the next hard drive

@@:
	mov	al, [orig_vds_flags]
	mov	es:[7Bh], al	; untell any lies about VDS support
	mov	ax, 254Bh	; restore int 4Bh vector
	lds	dx, [orig_int4B]
	int	21h

	; restore all our segments
	mov	ax, cs
	mov	ds, ax
	mov	es, ax

	mov	edx, [dodgy_int4B_retpoint]
	test	edx, edx
	jz	no_AHCIfix_fnd

	mov	ax, Device_Load_Ok
	jmp	init_exit
no_AHCIfix_fnd:
	mov	ax, Abort_Device_Load OR No_Fail_Message
init_exit:
	xor	bx, bx
	xor	si, si
	ret

EndProc AHCIfix_init

BeginProc tmp_int13
	int	3
	iret
EndProc tmp_int13

BeginProc tmp_int4B
	cmp	ax, 8104h	; UNLOCK DMA REGION
	jne	@F		; it's not the dodgy call that I know about...

	; Is the physical address set to zero?
	cmp	dword ptr es:[di.DD_physaddx], 0
	jnz	@F		; OK, not dodgy!

	; found it!
	pop	cs:[dodgy_int4B_retpoint]
	push	cs:[dodgy_int4B_retpoint]

@@:
	bt	cs:[orig_vds_flags], 5	; Is VDS *really* supported?
	jnc	@F
@@passthrough:
	jmp	cs:[orig_int4B]

@@:
	; * * * DUMMY INT 4Bh * * *
	cmp	ah, 81h	; really a VDS call?
	jne	@@passthrough
	cmp	al, 0Ch	; there are no functions above 0Ch
	ja	@@passthrough
	sub	al, 2	; there is no function zero or one
	jb	@@passthrough

	; What follows is a "dummy" implementation of the VDS int 4Bh, doing
	; the bare minimum to support the AHCI firmware (i.e. translating
	; addresses) while we look for dodgy calls!
	pushad
	mov	bp,sp

	movzx	bx,al
	shl	bx,1
	jmp	cs:@@jpt[bx]

@@jpt	dw	offset	@@version
	dw	offset	@@lock
@@pulck	dw	offset	@@done_ok
	dw	offset	@@lock_sg
	dw	offset	@@unlock_sg
	dw	offset	@@request_buf
	dw	offset	@@release_buf
	dw	offset	@@copyin_buf
	dw	offset	@@copyout_buf
	dw	offset	@@disable_xlat
	dw	offset	@@enable_xlat

@@version:
	mov	word ptr [bp.Pushad_EAX], 100h	; version 1.00
	mov	word ptr [bp.Pushad_EBX], "MD"	; "DM" for "dummy"!
	mov	word ptr [bp.Pushad_ECX], 0	; revision zero
	mov	word ptr [bp.Pushad_EDX], 1001b	; PC/XT bus, all mem contiguous
	mov	word ptr [bp.Pushad_EDI], 8000h	; max DMA buf size is
	mov	word ptr [bp.Pushad_ESI], 0	; 8000h, as per EMM386
	jmp	@@done_ok

@@lock:
	; I'm gonna ignore flags here and just give back the physical address...
	movzx	eax, es:[di.DD_segment]

	push	es
	push	40h
	pop	es
	cmp	ax, es:[0Eh]		; Is it locking in the EBDA?
	pop	es
	jne	@F

	cmp	es:[di.DD_offset], size scratchpad	; beginning of EBDA?
	jnb	@F

	; OK, firmware bug #2!
	; Need to back up what's in the EBDA and restore it later...
	call	backup_EBDA
	; patch the dispatch table above to restore on unlock!
	mov	cs:[@@pulck], offset @@unlock_special

@@:
	shl	eax, 4
	add	eax, es:[di.DD_offset]
	mov	es:[di.DD_physaddx], eax
	mov	es:[di.DD_bufid], 1	; make it non-zero just in case...
	jmp	@@done_ok

@@lock_sg:
	bt	dx, 6	; EDDS should be filled with page table entries?
	jc	@@fn_not_supported	; screw that!

	; I'm gonna ignore flags here and just give back the physical address...
	movzx	eax, word ptr es:[di.EDD_segment]
	shl	eax, 4
	add	eax, es:[di.EDD_offset]
	mov	es:[di.EDD_numused], 1	; only using one region
	mov	es:[di.EDD_physaddx], eax
	mov	eax, es:[di.EDD_size]
	mov	es:[di.EDD_physsize], eax
	jmp	@@done_ok

@@unlock_special:
	; unpatch immediately
	mov	cs:[@@pulck], offset @@done_ok

	push	es
	push	40h
	pop	es
	mov	es, es:[0Eh]		; EBDA

	; Restore what we backed up before...
	mov	cx, size EDD_Struc SHR 2
	xor	di, di
	lea	si, rminit_scratchpad
	cld
	rep	movs dword ptr es:[di], cs:[si]

	pop	es
	jmp	@@done_ok

@@request_buf:
@@release_buf:
@@copyin_buf:
@@copyout_buf:
	; I don't *think* we need these?
	int	3
@@fn_not_supported:
	mov	byte ptr [bp.Pushad_EAX], 0Fh	; function not supported
@@done_ng:
	bts	word ptr [bp+size Pushad_Struc+4], 0	; set CF on stack
	jmp	@F
@@unlock_sg:	; we don't need to do anything to unlock
@@disable_xlat:	; we don't need to do anything about
@@enable_xlat:	; DMA translation in Real Mode :)
@@done_ok:
	btr	word ptr [bp+size Pushad_Struc+4], 0	; clear CF on stack
@@:
	popad
	iret
EndProc tmp_int4B

BeginProc backup_EBDA
	push	cx
	push	di
	push	si
	push	es
	push	ds

	push	40h
	pop	ds
	mov	ds, ds:[0Eh]		; EBDA
	push	cs
	pop	es

	mov	cx, size EDD_Struc SHR 2
	xor	si, si
	lea	di, rminit_scratchpad
	cld
	rep	movsd

	pop	ds
	pop	es
	pop	si
	pop	di
	pop	cx

	ret
EndProc backup_EBDA

; dummy buffer to read a sector into
dummy_buf	db 200h dup (?)

VxD_REAL_INIT_ENDS


	END AHCIfix_init
