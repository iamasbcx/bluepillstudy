%include	"include/load.inc"
%include	"include/hdd.inc"
%include	"include/pm.inc"

org		OffsetOfLoader

	jmp	LABEL_START		; Start

; GDT ------------------------------------------------------------------------------------------------------------------------------------------------------------
;															段基址 			段界限 			属性
LABEL_GDT:						Descriptor 	0, 				0, 				0													; 空描述符
LABEL_DESC_FLAT_C:		Descriptor 	0, 				0xfffffff,		DA_CR    | DA_32 | DA_LIMIT_4K	; 0 ~ 4G
LABEL_DESC_FLAT_RW:	Descriptor 	0, 				0xfffffff,		DA_DRW | DA_32 | DA_LIMIT_4K	; 0 ~ 4G
LABEL_DESC_VIDEO:		Descriptor 	0xb8000, 	0xffff, 			DA_DRW | DA_DPL3	 					; 显存首地址
; GDT ------------------------------------------------------------------------------------------------------------------------------------------------------------

GdtLen		equ		$ - LABEL_GDT
GdtPtr		dw		GdtLen - 1												; 段界限
				dd		BaseOfLoader_PhyAddr + LABEL_GDT	; 基地址

; GDT 选择子 ----------------------------------------------------------------------------------
SelectorFlatC		equ		LABEL_DESC_FLAT_C		- LABEL_GDT
SelectorFlatRW		equ		LABEL_DESC_FLAT_RW	- LABEL_GDT
SelectorVideo		equ		LABEL_DESC_VIDEO		- LABEL_GDT
; GDT 选择子 ----------------------------------------------------------------------------------



BaseOfStack	equ	OffsetOfLoader

; 16-bit 实模式代码
LABEL_START:
	mov		ax, cs
	mov		ds, ax
	mov		es, ax
	mov		ss, ax
	mov		sp, BaseOfStack


; 获取内存布局 ----------------------------------------------------------
	mov		ebx, 0						; ebx = 后续值, 开始时需为 0
	mov		di, _MemChkBuf		; es:di 指向一个地址范围描述符结构（Address Range Descriptor Structure）
.MemChkLoop:
	mov		eax, 0xe820				; eax = 0000E820h
	mov		ecx, 20					; ecx = 地址范围描述符结构的大小
	mov		edx, 0x534D4150	; edx = 'SMAP'
	int		0x15						; int 15h
	jc			.MemChkFail
	add		di, 20
	inc		dword [_dwMCRNumber]	; dwMCRNumber = ARDS 的个数
	cmp		ebx, 0
	jne		.MemChkLoop
	jmp		.MemChkOK
.MemChkFail:
	mov		dword [_dwMCRNumber], 0
.MemChkOK:


; Load kernel file (origin ELF file) ----------------------------------------
	push 	es
	mov 	ax, 189					; Start from sector 190,
	mov 	dx, 0x1000				; to memory.
	mov 	bx, 0x0
.loop_ReadSec:
	push 	ax
	push 	dx
	call 		ReadSector
	pop 	dx
	pop 	ax
	
	inc 		ax
	add 		bx, 0x200 				; 内存地址偏移512字节
	cmp 	bx, 0x0000
	jne 		.loop_ReadSec

	add 		dx, 0x1000				; 段地址递增
	cmp 	dx, 0x8000
	jne 		.loop_ReadSec

	pop 	es

	
; 准备跳入保护模式 -------------------------------------------
	lgdt		[GdtPtr] 					; 加载 GDTR
	cli 										; 关中断

	in			al, 0x92					; 打开地址线A20
	or			al, 00000010b
	out		0x92, al

	mov		eax, cr0 					; 设置CR0，打开保护模式
	or			eax, 1
	mov		cr0, eax

; 进入保护模式 -------------------------------------------------
	jmp		dword SelectorFlatC:(BaseOfLoader_PhyAddr+LABEL_PM_START)



;----------------------------------------
;	Function: 		ReadSector
; 	Description:	Read sectors from hard disk.
; 	NOTE:			Using BIOS interrupt service 13H, function 02H.
;		INT 13H，AH=02H 读扇区:
;		入口参数：
;			AH=02H 指明调用读扇区功能。
;			AL 置要读的扇区数目，不允许使用读磁道末端以外的数值，也不允许使该寄存器为0。
;			DL 需要进行读操作的驱动器号。
;			DH 所读磁盘的磁头号。
;			CH 磁道号的低8位数。
;			CL 低6位放入所读起始扇区号，位7-6表示磁道号的高2位。
;			ES:BX 读出数据的缓冲区地址。
;		返回参数：
;			如果CF=1，AX中存放出错状态。读出后的数据在ES:BX区域依次排列。
;
; -----------------------------------------------------------------------
; 怎样由扇区号求扇区在磁盘中的位置 (扇区号 -> 柱面号, 起始扇区, 磁头号)
; -----------------------------------------------------------------------
; 设扇区号为 x （起始扇区号为0）
;                                          ┌ 柱面号 = y / 磁头数
;       x                      ┌ 商 y ┤
; ------------------- => ┤         └ 磁头号 = y / 磁头数 的余数
;  每磁道扇区数      │
;                               └ 余 z => 起始扇区号 = z + 1
;----------------------------------------
ReadSector:
	mov 	es, dx				; es的值存放在dx中

	push	bx					; 保存 bx
	mov		bl, SecPerTrk	; bl: 除数
	div		bl						; y 在 al 中, z 在 ah 中
	inc 		ah
	mov		cl, ah				; cl <- 起始扇区号
	xor 		ah, ah
	mov 	bl, HeadsNum	; 磁头数
	div 		bl 					; y/HeadsNum
	mov 	ch, al 				; ch <- 柱面号
	mov 	dh, ah 				; dh <- 磁头号
	pop		bx					; 恢复 bx
	; 至此, "柱面号, 起始扇区, 磁头号" 全部得到 ^^^^^^^^^^^^^^^^^^^^^^^^
	mov		dl, DrvNum		; 驱动器号
.GoOnReading:
	mov		ah, 0x02			; 读
	mov		al, 1					; 读 1 个扇区
	int		0x13				; int 13h
	jc			.GoOnReading	; 如果读取错误 CF 会被置为 1, 这时就不停地读, 直到正确为止

	ret



; 32-bit 保护模式代码段
[SECTION .s32]
ALIGN	32
[BITS	32]

LABEL_PM_START:
	mov		ax, SelectorVideo
	mov		gs, ax
	mov		ax, SelectorFlatRW
	mov		ds, ax
	mov		es, ax
	mov		fs, ax
	mov		ss, ax
	mov		esp, TopOfStack

	push	szMemChkTitle				; 显示内存信息标题
	call		DispStr
	add		esp, 4

	call		DispMemInfo 				; 显示内存信息

	mov 	eax, [dwMemSize] 		; 将内存大小写入到指定地址
	mov 	[MemSizeInfo_PhyAddr], eax

	call		InitKernel 						; 解析kernel 的ELF 格式，将kernel 代码在内存中重定位

	jmp		SelectorFlatC:KernelEntryPoint_PhyAddr		; 进入内核



%include "include/asm_pm_display_lib.inc"


; ------------------------------------------------------------------------
; 内存拷贝，仿 memcpy
; ------------------------------------------------------------------------
; void* MemCpy(void* es:pDest, void* ds:pSrc, int iSize);
; ------------------------------------------------------------------------
MemCpy:
	push	ebp
	mov		ebp, esp
	push	esi
	push	edi
	push	ecx

	mov		edi, [ebp + 8]			; Destination
	mov		esi, [ebp + 12]			; Source
	mov		ecx, [ebp + 16]		; Counter
.1:
	cmp		ecx, 0						; 判断计数器
	jz			.2								; 计数器为零时跳出

	mov		al, [ds:esi]				; ┓
	inc		esi							; ┃
												; ┣ 逐字节移动
	mov		byte [es:edi], al		; ┃
	inc		edi							; ┛

	dec		ecx							; 计数器减一
	jmp		.1								; 循环
.2:
	mov		eax, [ebp + 8]			; 返回值

	pop		ecx
	pop		edi
	pop		esi
	mov		esp, ebp
	pop		ebp
	ret
; MemCpy 结束-------------------------------------------------------------



; 显示内存信息 --------------------------------------------------------------
DispMemInfo:
	push		esi
	push		edi
	push		ecx

	mov			esi, MemChkBuf
	mov			ecx, [dwMCRNumber]		;for(int i=0;i<[MCRNumber];i++) 
.loop:												;{// 每次得到一个ARDS(Address Range Descriptor Structure)结构
	mov			edx, 5								;	for(int j=0;j<5;j++)	// 每次得到一个ARDS中的成员，共5个成员
	mov			edi, ARDStruct					;	{	// 依次显示：BaseAddrLow，BaseAddrHigh，LengthLow，LengthHigh，Type
.1:													;
	push		dword [esi]						;
	call			DispInt								;		DispInt(MemChkBuf[j*4]); // 显示一个成员
	pop			eax									;
	stosd											;		ARDStruct[j*4] = MemChkBuf[j*4];
	add			esi, 4								;
	dec			edx									;
	cmp			edx, 0								;
	jnz			.1										;	}
	call			DispReturn						;	printf("\n");
	cmp			dword [dwType], 1			;	if(Type == AddressRangeMemory) // AddressRangeMemory : 1, AddressRangeReserved : 2
	jne			.2										;	{
	mov			eax, [dwBaseAddrLow]	;
	add			eax, [dwLengthLow]		;
	cmp			eax, [dwMemSize]			;		if(BaseAddrLow + LengthLow > MemSize)
	jb				.2										;
	mov			[dwMemSize], eax			;			MemSize = BaseAddrLow + LengthLow;
.2:													;	}
	loop			.loop								;}
														;
	call			DispReturn						;printf("\n");
	push		szRAMSize						;
	call			DispStr								;printf("RAM size:");
	add			esp, 4								;
														;
	push		dword [dwMemSize]		;
	call			DispInt								;DispInt(MemSize);
	add			esp, 4								;

	pop			ecx
	pop			edi
	pop			esi
	ret
; ---------------------------------------------------------------------------



; InitKernel ---------------------------------------------------------------------------------
; 将 kernel file 的内容经过ELF 格式解析后重定位
; --------------------------------------------------------------------------------------------
InitKernel:	
	; 遍历每一个 Program Header，根据 Program Header 中的信息来确定把什么放进内存，放到什么位置，以及放多少。
	xor			esi, esi
	mov			cx, word [BaseOfKernelFile_PhyAddr + 2Ch]	; ┓ ecx <- pELFHdr->e_phnum
	movzx		ecx, cx																; ┛
	mov			esi, [BaseOfKernelFile_PhyAddr + 1Ch]			; esi <- pELFHdr->e_phoff
	add			esi, BaseOfKernelFile_PhyAddr							; esi <- OffsetOfKernel + pELFHdr->e_phoff
.Begin:
	mov			eax, [esi + 0]
	cmp			eax, 0																; PT_NULL
	jz				.NoAction
	push		dword [esi + 010h]						; size	┓
	mov			eax, [esi + 04h]							;	┃
	add			eax, BaseOfKernelFile_PhyAddr	;	┣ ::memcpy(	(void*)(pPHdr->p_vaddr),
	push		eax											; src	┃		uchCode + pPHdr->p_offset,
	mov 		eax, [esi + 0x08] 					; dst	┃		pPHdr->p_filesz;
	and 			eax, 0xffffff 								; !! for JOS, p_vaddr & 0xffffff, 即实际放在1MB 开始的物理地址
	push 		eax
	call			MemCpy										;	┃
	add			esp, 12										;	┛
.NoAction:
	add			esi, 020h										; esi += pELFHdr->e_phentsize
	dec			ecx
	jnz			.Begin

	ret
; InitKernel ^^^^^^^^^^^^^^^^^^^^^^^^^^^^



MEM_INFO_LEN 	equ 	512

; 数据段
[SECTION .data]
ALIGN	32
LABEL_DATA:
; 实模式下使用这些符号
; 字符串
_szMemChkTitle:			db	"BaseAddrL BaseAddrH LengthLow LengthHigh   Type", 0Ah, 0
_szRAMSize:					db	"RAM size:", 0
_szReturn:					db	0Ah, 0
;; 变量
_dwMCRNumber:			dd	0	; Memory Check Result
_dwDispPos:				dd	(80 * 10 + 0) * 2	; 屏幕第 6 行, 第 0 列。
_dwMemSize:				dd	0
_ARDStruct:		; Address Range Descriptor Structure
	_dwBaseAddrLow:	dd	0
	_dwBaseAddrHigh:	dd	0
	_dwLengthLow:		dd	0
	_dwLengthHigh:		dd	0
	_dwType:					dd	0
_MemChkBuf:				times	MEM_INFO_LEN	db	0
;
;; 保护模式下使用这些符号
szMemChkTitle				equ		BaseOfLoader_PhyAddr + _szMemChkTitle
szRAMSize					equ		BaseOfLoader_PhyAddr + _szRAMSize
szReturn						equ		BaseOfLoader_PhyAddr + _szReturn
dwDispPos					equ		BaseOfLoader_PhyAddr + _dwDispPos
dwMemSize					equ		BaseOfLoader_PhyAddr + _dwMemSize
dwMCRNumber			equ		BaseOfLoader_PhyAddr + _dwMCRNumber
ARDStruct					equ		BaseOfLoader_PhyAddr + _ARDStruct
	dwBaseAddrLow		equ		BaseOfLoader_PhyAddr + _dwBaseAddrLow
	dwBaseAddrHigh		equ		BaseOfLoader_PhyAddr + _dwBaseAddrHigh
	dwLengthLow			equ		BaseOfLoader_PhyAddr + _dwLengthLow
	dwLengthHigh			equ		BaseOfLoader_PhyAddr + _dwLengthHigh
	dwType					equ		BaseOfLoader_PhyAddr + _dwType
MemChkBuf					equ		BaseOfLoader_PhyAddr + _MemChkBuf


; 堆栈在数据段的末尾
StackSpace:					times	0x1000	db	0
TopOfStack					equ		BaseOfLoader_PhyAddr + $	; 栈顶