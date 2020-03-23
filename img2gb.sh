#!/bin/bash

# set -uex
set -ue

if [ $# -ne 2 ]; then
	echo "Usage: $0 SRC_IMG_FILE DST_GB_FILE" 1>&2
	exit 1
fi

SRC_IMG_FILE=$1
DST_GB_FILE=$2

temp_2bpp_dir=2bpp
rm -rf $temp_2bpp_dir

. include/common.sh
. include/lr35902.sh
. include/gb.sh

print_prog_const() {
	# タイルデータ(16バイト)
	cat $temp_2bpp_dir/*
}

print_prog_main() {
	# 割り込みは使わないので止める
	lr35902_disable_interrupts

	# SPをFFFE(HMEMの末尾)に設定
	lr35902_set_regHL_and_SP fffe

	# スクロールレジスタクリア
	gb_reset_scroll_pos

	# パレット初期化
	gb_set_palette_to_default

	# V-Blankの開始を待つ
	gb_wait_for_vblank_to_start

	# LCDを停止する
	# - 停止の間はVRAMとOAMに自由にアクセスできる(vblankとか関係なく)
	# - Bit 7の他も明示的に設定

	# [LCD制御レジスタの設定値]
	# - Bit 7: LCD Display Enable (0=Off, 1=On)
	#   -> LCDを停止させるため0
	# - Bit 6: Window Tile Map Display Select (0=9800-9BFF, 1=9C00-9FFF)
	#   -> 9800-9BFFは背景に使うため、
	#      ウィンドウタイルマップには9C00-9FFFを設定
	# - Bit 5: Window Display Enable (0=Off, 1=On)
	#   -> ウィンドウは使わないので0
	# - Bit 4: BG & Window Tile Data Select (0=8800-97FF, 1=8000-8FFF)
	#   -> タイルデータの配置領域は8000-8FFFにする
	# - Bit 3: BG Tile Map Display Select (0=9800-9BFF, 1=9C00-9FFF)
	#   -> 背景用のタイルマップ領域に9800-9BFFを使う
	# - Bit 2: OBJ (Sprite) Size (0=8x8, 1=8x16)
	#   -> スプライトはまだ使わないので適当に8x8を設定
	# - Bit 1: OBJ (Sprite) Display Enable (0=Off, 1=On)
	#   -> スプライトはまだ使わないので0
	# - Bit 0: BG Display (0=Off, 1=On)
	#   -> 背景は使うので1

	lr35902_set_reg regA 51
	# lr35902_set_reg regA 41
	lr35902_copy_to_ioport_from_regA $GB_IO_LCDC

	# タイルデータをVRAMのタイルデータ領域へロード
	lr35902_set_reg regBC 0012
	lr35902_set_reg regDE 0150
	lr35902_set_reg regHL 8000

	lr35902_push_reg regBC
	lr35902_set_reg regBC 0140
	lr35902_copy_to_from regA ptrDE
	lr35902_copy_to_from ptrHL regA
	lr35902_inc regDE
	lr35902_inc regHL
	lr35902_dec regBC
	lr35902_clear_reg regA
	lr35902_compare_regA_and regC
	lr35902_rel_jump_with_cond NZ $(two_comp 09)
	lr35902_compare_regA_and regB
	lr35902_rel_jump_with_cond NZ $(two_comp 0c)
	lr35902_pop_reg regBC
	lr35902_dec regC
	lr35902_rel_jump_with_cond NZ $(two_comp 14)

	# タイル番号をVRAMの背景用タイルマップ領域へ設定
	lr35902_clear_reg regA
	lr35902_set_reg regHL 9800
	lr35902_set_reg regB 12	# 縦に18タイル(* 18 8)144
	lr35902_set_reg regC 14	# 横に20タイル(* 20 8)160
	lr35902_copyinc_to_ptrHL_from_regA
	lr35902_inc regA
	lr35902_dec regC
	lr35902_rel_jump_with_cond NZ $(two_comp 05)
	lr35902_set_reg regDE 000c	# 12タイル分(12バイト)飛ばす
	echo -en '\x19'	# add hl,de
	lr35902_dec regB
	lr35902_rel_jump_with_cond NZ $(two_comp 0e)

	# 高さ半分の位置(LY=74)でLCDCステータス割り込み(INT:48)を上げるようにする
	lr35902_set_reg regA 48
	lr35902_copy_to_ioport_from_regA $GB_IO_LYC
	lr35902_copy_to_regA_from_ioport $GB_IO_STAT
	echo -en '\xcb\xf7'	# set 6,a
	lr35902_copy_to_ioport_from_regA $GB_IO_STAT

	# V-Blank(b0)とLCD STAT(b1)の割り込みのみ有効化
	lr35902_set_reg regA 03
	lr35902_copy_to_ioport_from_regA $GB_IO_IE

	# 割り込み有効化
	lr35902_enable_interrupts

	# LCD再開
	lr35902_set_reg regA d1
	# lr35902_set_reg regA c1
	lr35902_copy_to_ioport_from_regA $GB_IO_LCDC

	# 割り込み駆動の処理部
	lr35902_halt
	lr35902_disable_interrupts

	lr35902_copy_to_regA_from_addr c000
	lr35902_copy_to_from regB regA

	# V-Blank割り込み時の処理
	echo -en '\xcb\x40'	# bit 0,b
	lr35902_rel_jump_with_cond Z 08
	lr35902_copy_to_regA_from_ioport $GB_IO_LCDC	# 2 bytes
	echo -en '\xcb\xe7'	# set 4,a
	lr35902_copy_to_ioport_from_regA $GB_IO_LCDC
	echo -en '\xcb\x80'	# res 0,b

	# LCDステータス割り込み時の処理
	echo -en '\xcb\x48'	# bit 1,b
	lr35902_rel_jump_with_cond Z 08
	lr35902_copy_to_regA_from_ioport $GB_IO_LCDC
	echo -en '\xcb\xa7'	# res 4,a
	lr35902_copy_to_ioport_from_regA $GB_IO_LCDC
	echo -en '\xcb\x80'	# res 0,b

	lr35902_copy_to_from regA regB
	lr35902_copy_to_addr_from_regA c000

	lr35902_enable_interrupts
	lr35902_rel_jump $(two_comp 26)
}

print_vector_table() {
	# 今回の場合、割り込みが有効化されるのは
	# メインの処理がアイドルになってからなので
	# 割り込みハンドラで使用するレジスタの退避/復帰は省略

	dd if=/dev/zero bs=1 count=48 2>/dev/null

	# 0030: V-Blank割り込みハンドラ本体(8バイト)
	lr35902_push_reg regAF
	lr35902_set_reg regA 01
	lr35902_copy_to_addr_from_regA c000
	lr35902_pop_reg regAF
	lr35902_ei_and_ret

	# 0038: LCDステータス割り込みハンドラ本体(8バイト)
	lr35902_push_reg regAF
	lr35902_set_reg regA 02
	lr35902_copy_to_addr_from_regA c000
	lr35902_pop_reg regAF
	lr35902_ei_and_ret

	# 0040: V-Blank割り込み
	echo -en '\xc3\x30\x00'	# jp $0030
	dd if=/dev/zero bs=1 count=5 2>/dev/null

	# 0048: LCDステータス割り込み
	echo -en '\xc3\x38\x00'	# jp $0038
	dd if=/dev/zero bs=1 count=5 2>/dev/null

	# 0050: タイマー割り込み
	lr35902_ei_and_ret
	dd if=/dev/zero bs=1 count=7 2>/dev/null

	# 0058: シリアル割り込み
	lr35902_ei_and_ret
	dd if=/dev/zero bs=1 count=7 2>/dev/null

	# 0060: ジョイパッド割り込み
	lr35902_ei_and_ret
	dd if=/dev/zero bs=1 count=159 2>/dev/null
}

print_cart_header() {
	local offset=$(print_prog_const | wc -c)
	local offset_hex=$(echo "obase=16;${offset}" | bc)
	local bc_form="obase=16;ibase=16;${GB_ROM_START_ADDR}+${offset_hex}"
	local entry_addr=$(echo $bc_form | bc)
	bc_form="obase=16;ibase=16;${entry_addr}+10000"
	local entry_addr_4digits=$(echo $bc_form | bc | cut -c2-5)

	gb_cart_header_no_title $entry_addr_4digits
}

print_cart_rom() {
	print_prog_const
	print_prog_main

	# 32KBのサイズにするために残りをゼロ埋め
	local num_const_bytes=$(print_prog_const | wc -c)
	local num_main_bytes=$(print_prog_main | wc -c)
	local padding=$((GB_CART_ROM_SIZE - num_const_bytes - num_main_bytes))
	dd if=/dev/zero bs=1 count=$padding 2>/dev/null
}

print_rom() {
	# 0x0000 - 0x00ff: リスタートと割り込みのベクタテーブル (256バイト)
	print_vector_table

	# 0x0100 - 0x014f: カートリッジヘッダ (80バイト)
	print_cart_header

	# 0x0150 - 0x7fff: カートリッジROM (32432バイト)
	print_cart_rom
}

tool/img22bpptiles.sh $SRC_IMG_FILE $temp_2bpp_dir
print_rom >$DST_GB_FILE
