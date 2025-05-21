ENTRY(_start)

SECTIONS {
	. = 2M;
	_start = .;
	.text : ALIGN(4K) {
		*(.text .text.*)
	}

	.rodata : ALIGN(4K) {
		*(.rodata .rodata.*)
	}

	.data : ALIGN(4K) {
		*(.data .data.*)
	}

	.bss : ALIGN(4K) {
		_bss_start = .;
		*(.bss .bss.*)
		_bss_end = .;
	}
	_end = .;
}
