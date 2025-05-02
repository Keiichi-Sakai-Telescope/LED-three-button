;;						processor	16f1823
						#include	p16F1823.inc

						errorlevel -302
						radix	DEC

 __config	_CONFIG1,	_FCMEN_OFF & _IESO_OFF & _CLKOUTEN_OFF & _BOREN_ON & _CPD_OFF & _CP_OFF & _MCLRE_OFF & _PWRTE_OFF & _WDTE_OFF & _FOSC_INTOSC
 __config	_CONFIG2,	_WRT_OFF & _PLLEN_OFF & _STVREN_ON & _BORV_LO & _LVP_OFF

#define	SW_L			PORTA,2		; RA2 : active L input
#define	SW_R			PORTA,3		; RA3 : active L input
#define	SW_C			CM1CON0,6	; active L state of C1OUT in CM1CON0
#define	PIN_VREF_LO		LATA,1		; ICSPCLK/RA1 : digital output only	1: low volatage, Hi-Z: mid. voltage, 0: high voltage
#define	GATE_REG		LATA,4		; RA4 : digital output	1: REGULAOR ON
#define	PIN_CALIB		LATA,5		; current source for caribration: digital output only
#define	TRIS_VREF		TRISA,1
#define TRIS_CALIB		TRISA,5
;						PORTA,0		; ICSPDAT/DACOUT

PORTC_RED2_LO			equ		B'000100'
PORTC_RED2_HI			equ		B'010100'
PORTC_WHITE1_LO			equ		B'100000'
PORTC_WHITE1_HI			equ		B'110000'
PORTC_WHITE3_LO			equ		B'101000'
PORTC_WHITE3_HI			equ		B'111000'

; DAC table
FLAG_HI					equ		B'11000000'
FLAG_MID				equ		B'10000000'
FLAG_LOW				equ		B'01000000'
FLAG_LOWEST				equ		B'00000000'

FVR_mV:					equ		2048		; [mV]
LED_IVC_LO_mOHM:		equ		83200		; [mOhm]	for I-V conversion resister
LED_IVC_HI_mOHM:		equ		8200		; [mOhm]	for I-V conversion resister
CALIBRATION_R_kOHM		equ		5			; [kOhm]

; ADCON0					  - CHS4 CHS3 CHS2 CHS1 CHS0 GO ADON
ADCON0_ILED				equ		B'00010001'	; x, 00100(AN4), 0(DONE), ADON
; ADCON1			ADFM ADCS2 ADCS1 ADCS0 - - ADPREF1 ADPREF0
ADCON1_ILED				equ		B'01000011'	; left, 100 for TAD = 2us (Fosc/4), 00, 11 for FVR

LED_STATE_MASK			equ		0x1F		; {sequence, Setup, guard, White, index[3:0]}
LED_STATE_WHITE_MASK	equ		0x10
DISCHARGE_TIME			equ		10			; 1 tick is 1024[us], up to 0.25[sec]
BLINK_TIME:				equ		200			; 1 tick is 1024[us], up to 0.25[sec]
LP_TIME:				equ		1000/10		; 1 tick is 10[ms], up to 2.55[sec]
OFF_TIME:				equ		0			; 1 tick is 10[ms], up to 655.35[sec]
;OFF_TIME:				equ		60000/10	; 1 tick is 10[ms], up to 655.35[sec]

; file register allocation
LED_STATE				equ		0x70		; current state of LEDs, it is equal to (EEDATA & 0x1F)
DEVICE_STATE			equ		0x71		; current state of device control
SW_TRANSIENT			equ		0x72		; transient state of SW
SW_STATE				equ		0x73		; current state of SW
SW_TIMER				equ		0x74		; timer for long pressing
OFF_TIMER_L				equ		0x75		; timer for auto off
OFF_TIMER_H				equ		0x76
ILED_AVERAGE_L			equ		0x77
ILED_AVERAGE_M			equ		0x78
ILED_AVERAGE_H			equ		0x79
ADC_OFFSET_L			equ		0x7A
ADC_OFFSET_M			equ		0x7B
ADC_OFFSET_H			equ		0x7C
W1						equ		0x7E
W2						equ		0x7F

BIT_SW_STATE_L			equ		0
BIT_SW_STATE_R			equ		1
BIT_SW_STATE_C			equ		2
MASK_SW_STATE_RL		equ		((1<<BIT_SW_STATE_L)|(1<<BIT_SW_STATE_R))
MASK_SW_STATE_C			equ		(1<<BIT_SW_STATE_C)
#define	SW_STATE_L		SW_STATE,BIT_SW_STATE_L
#define	SW_STATE_R		SW_STATE,BIT_SW_STATE_R
#define	SW_STATE_C		SW_STATE,BIT_SW_STATE_C

; 設定電圧[v] = 2.42 + 2.42/44*50*VR_STATE/63
; 測定電流[mA] = 設定電圧*(ADRES_LED/1024)/4.0
; C503で約15オーム、SSLで約10オーム。
; A/Dの精度は±2LSB。
; 整定時間は、MUX操作後からGO=1設定までの時間、12us見ればOK

; Reset vector
						org		0x000
reset_vector:			goto	start

;	*	*	*	*	*	*	*	
;	昇圧DC-DCコンバータの電圧を設定するルーチン
;	*	*	*	*	*	*	*	
;
; LEDの電流をLED_STATEに基づいて制御する。
; MCP4012を設定します。
;
;	白LEDはEEDATA[3:0]の16段階
;	赤LEDはEEDATA[3:0]の16段階
;	bit7:	sequence bit(EEADRLのwrap roundで変える)
;	bit6:	0
;	bit5:	0
;	bit4:	1: white, 0: red
;	bit3-0:	brightness index

; 0	ADCON0.GO is set by CCP1
; 1	A/D conversion start
; 3-5	CCP1 interrupt occur
; 11-	A/D conversion end
					org		0x004
CCP1_intr:			; W, STATUS, BSR, FSRs, PCLATH are shadowed
					; latency 3-4 for synchronous, 3-5 for asynchronous
					BANKSEL	0
					bcf		PIR1,CCP1IF		;		3-5

					moviw	0[FSR1]			; PORTC value
					movwf	PORTC

					; average -= desired
					moviw	1[FSR1]			; lower byte of desired LED current
					subwf	ILED_AVERAGE_L,F
					moviw	2[FSR1]			; higher byte of desired LED current
					subwfb	ILED_AVERAGE_M,F
					clrw
					subwfb	ILED_AVERAGE_H,F

					; average -= offset
					movf	ADC_OFFSET_L
					subwf	ILED_AVERAGE_L,F
					movf	ADC_OFFSET_M
					subwfb	ILED_AVERAGE_M,F
					movf	ADC_OFFSET_H
					subwfb	ILED_AVERAGE_H,F

					; average += supplied
					BANKSEL	ADRESL
					movf	ADRESL,W
					addwf	ILED_AVERAGE_L,F
					movf	ADRESH,W
					addwfc	ILED_AVERAGE_M,F
					clrw
					addwfc	ILED_AVERAGE_H,F

					; I (integral) control
					asrf	ILED_AVERAGE_H,W	; valid range: 0x000000-0x01FFFF
					btfss	STATUS,Z
					goto	saturation
					rrf		ILED_AVERAGE_M,W
					lsrf	WREG,W
					addlw	LOW vref_table
					movwf	FSR0L
					moviw	0[FSR0]

					btfss	WREG,7
					bra		dac_low_lowest
dac_hi_mid:			btfsc	WREG,6
					bcf		TRIS_VREF	; dac high
					btfss	WREG,6
					bsf		TRIS_VREF	; dac mid.

					BANKSEL	LATA
					bcf		PIN_VREF_LO
					movwf	DACCON1
					bsf		DACCON0,DACEN
					retfie

dac_low_lowest:		bcf		TRIS_VREF

					BANKSEL	LATA
					bsf		PIN_VREF_LO
					movwf	DACCON1
					btfsc	WREG,6
					bsf		DACCON0,DACEN	; dac low
					btfss	WREG,6
					bcf		DACCON0,DACEN	; dac lowest
					retfie

saturation:			bcf		TRIS_VREF
					BANKSEL	LATA
					movlw	-1
					btfss	ILED_AVERAGE_H,7
					goto	cut_to_ul
			
cut_to_ll:			bcf		PIN_VREF_LO
					clrf	DACCON1
					bsf		DACCON0,DACEN
					movwf	ILED_AVERAGE_L
					movwf	ILED_AVERAGE_M
					movwf	ILED_AVERAGE_H		; 0xFFFFFF
					retfie

cut_to_ul:			bsf		PIN_VREF_LO
					movwf	DACCON1
					bcf		DACCON0,DACEN
					clrf	ILED_AVERAGE_L
					clrf	ILED_AVERAGE_M
					clrf	ILED_AVERAGE_H
					bsf		ILED_AVERAGE_H,1	; 0x020000
					retfie

; クロック設定
; I/Oを安全なモードにする
; コンフィグかどうか判定する
start:
					; change clock speed
					BANKSEL	OSCCON
					movlw	B'01100000'	; PLL off, IRCF = 1100 for HFINTOSC 2MHz
					movwf	OSCCON		; SPLLEN, IRCF<3:0>, 00, SCS<1:0>

					; setup pin function
;					BANKSEL	TRISA
					movlw	B'00101101'	; digital out: RA4, analog out: RA1
					movwf	TRISA
					movlw	B'00000011'
					movwf	TRISC		; digital out: RC5, RC4, RC3, RC2

					movlw	B'01010010'	; bit7: clear RAPU to enable pull-up
					movwf	OPTION_REG	; bit6: default(Interrupt on rising edge of INT pin)
								; bit5: clock source for Timer 0 is from Fosc/4
								; bit4: default(Increment on H-to-L on T0CKI pin)
								; bit3: prescaler is assigned to Timer0
								; bit2-0: 1:8 prescaler

					BANKSEL	LATA
					movlw	-1
					movwf	LATA		; RA5=RA4=RA1=1
					clrf	LATC		; RC5=RC4=RC3=RC2=0 to keep LED off

					BANKSEL	WPUA
					movlw	B'001100'	; digital input: RA3, RA2
					movwf	WPUA
					clrf	WPUC
					
					BANKSEL	ANSELA
					movlw	B'00100011'
					movwf	ANSELA		; analog out: RA5, RA1, RA0
					movlw	B'00000011'
					movwf	ANSELC		; analog in: RC1(C12IN1-), RC0(AN4)

					; Fixed Voltage for ADC and SW_C
					BANKSEL	FVRCON
					movlw	B'11001010'	; CDAFVR<1:0> = ADFVR<1:0> = 10 for 2.048V
					movwf	FVRCON		; FVREN FVRRDY TSEN TSRNG CDAFVR<1:0> ADFVR<1:0>

					; Comparator for SW_C
;					BANKSEL	CM1CON0
					movlw	B'10010010'	; on    -      off   inv.   0  low   on     no
					movwf	CM1CON0		; C1ON, C1OUT, C1OE, C1POL, 0, C1SP, C1HYS, C1SYNC
					movlw	B'00100001'	; no interrupt  FVR        00 C12IN1-
					movwf	CM1CON1		; C1INTP C1INTN C1PCH<1:0> 00 C1NCH<1:0>

					; read SW_C voltage
					goto	$+1
					btfsc	SW_C
					goto	power_off
					bcf		CM1CON0,C1ON	; shutdown comparator

					; setup ADC
					BANKSEL	ADCON0
					movlw	ADCON0_ILED
					movwf	ADCON0
					movlw	ADCON1_ILED
					movwf	ADCON1

					; set to the lowest voltage
					call 	dac_init

#if 0
					; acquire I-V curve
					call	acquire_iv
#endif

					; calibration adc
					call	calibration	; modify FSR0, FSR1

					; restore LED_STATE and setup LED controller
					call	eeprom_read

					; setup pointer to Vref table
					movlw	HIGH vref_table
					movwf	FSR0H

#if OFF_TIME == 0
					; setup SW
					clrf	OFF_TIMER_L	; 消灯タイマは使わない
					clrf	OFF_TIMER_H
					movlw	LP_TIME		; 長押しタイマを設定 for color change
					movwf	SW_TIMER
					movlw	MASK_SW_STATE_C	; 電源投入: SW_C=1
					movwf	SW_TRANSIENT
					movwf	SW_STATE

					; setup device state
					movlw	LOW fsm_color_change_wait
					movwf	DEVICE_STATE
					movlw	HIGH fsm_color_change_wait
					movwf	PCLATH
#else
					; setup SW
					movlw	LOW OFF_TIME	; 消灯タイマを設定
					movwf	OFF_TIMER_L
					movlw	HIGH OFF_TIME
					movwf	OFF_TIMER_H
					movlw	LP_TIME/2	; 長押しタイマを設定
					movwf	SW_TIMER
					movlw	MASK_SW_STATE_C	; 電源投入: SW_C=1
					movwf	SW_TRANSIENT
					movwf	SW_STATE

					; setup device state
					movlw	LOW fsm_por_release_wait	; por_release_waitに遷移
					movwf	DEVICE_STATE
					movlw	HIGH fsm_por_release_wait
					movwf	PCLATH
#endif

; current control perio:	200us (100 instruction cycle) controlled by CCP1
; key scan period:		10000us controlled by Timer2
					BANKSEL	CCPR1L
					movlw	49		; 50*2 instruction cycle  = 200us
					movwf	CCPR1L
					clrf	CCPR1H
					movlw	B'00001011'	; Compare mode, special event trigger
					movwf	CCP1CON

					BANKSEL	0
					; setup timer1 for time base of LED controller
					clrf	TMR1L
					clrf	TMR1H
					movlw	B'00010001'	; T1CKPS=01 for 1:2 prescaler, Timer1 ON
					movwf	T1CON	; TMR1CS<1:0>, T1CKPS<1:0>, T1OSCEN, T1SYNC, 0, TMR1ON
					bcf		PIR1,CCP1IF

					; setup timer2 for key switch handling
					movlw	124		; 4*125*10 = 10000 instruction cycle = 10000us
					movwf	PR2
					bcf		PIR1,TMR2IF
					movlw	B'01001101'	; 0, 1001 for 1:10 post, ON, 01 for 1:4 pre
					movwf	T2CON

					; enable interrupt
					BANKSEL	PIE1
					bsf		PIE1,CCP1IE
					bsf		INTCON,GIE
					bsf		INTCON,PEIE
; 通常処理
main_loop:			call	ctrl_state	; SWの状態により、デバイスの動作状態を変更
					goto	main_loop

; LEDを消して、レギュレータを停止し、WDTを常に更新する無限ループに入る
power_off:		
					BANKSEL	LATA
					clrf	LATC
					bcf		GATE_REG
					clrwdt
					goto	$-1

;	*	*	*	*	*	*	*	
;	EEPROMの管理
;	*	*	*	*	*	*	*	

; LED_STATEをEEPROMに書く。ただし、変更があったときだけ。
eeprom_update:
					BANKSEL	EEDATL
					btfss	EECON1,WREN	; check write request
					btfsc	EECON1,WR	; is writing in progress ?
					return			; ふつうはありえない。

					lslf	LED_STATE,W	; update pointer
					addwf	LED_STATE,W
					movwf	FSR1L

					incf	EEADRL,F
					bsf		EECON1,RD
					movf	EEDATL,W
					andlw	0x80
					xorlw	0x80
					iorwf	LED_STATE,W
					movwf	EEDATL
					bsf		EECON1,WREN	; set WREN to initiate write

					bcf		INTCON,GIE	; disable intterupts
					movlw	0x55		; Unlock write
					movwf	EECON2
					movlw	0xAA
					movwf	EECON2
					bsf		EECON1,WR 	; Start the write
					bsf		INTCON,GIE	; enable intterupts
					bcf		EECON1,WREN	; Disable write
					return
		
; EEPROMからLED_STATEを読む
; EEDATA: LEDの状態はLED_STATE_MASKでマスクした部分。
eeprom_read:
					BANKSEL	EEDATL
					clrf	EEADRL
					clrf	EEADRH
					bcf		EECON1,CFGS
					bcf		EECON1,EEPGD

					bsf		EECON1,RD
					btfss	EEDATL,7		; bit7 is sequence bit
					goto	eeprom_search0
eeprom_search1:		decf	EEADRL,F
					bsf		EECON1,RD
					btfss	EEDATL,7		; is sequence bit 1 ?
					goto	eeprom_search1
					goto	eeprom_found
eeprom_search0:		decf	EEADRL,F
					bsf		EECON1,RD
					btfsc	EEDATL,7		; is sequence bit 0 ?
					goto	eeprom_search0
eeprom_found:		movf	EEDATL,W
					andlw	LED_STATE_MASK
					movwf	LED_STATE

					movlw	HIGH led_table		; set pointer to led_table
					movwf	FSR1H
					lslf	LED_STATE,W
					addwf	LED_STATE,W
					movwf	FSR1L
					return

; set DAC to get lowest voltage
dac_init:
					BANKSEL	DACCON0
					movlw	B'01101000'
					movwf	DACCON0
					movlw	-1
					movwf	DACCON1

;					BANKSEL	LATA
					bsf		PIN_VREF_LO

					BANKSEL	TRISA
					bcf		TRIS_VREF

					clrf	ILED_AVERAGE_L
					movlw	LOW ((vref_default-vref_table)*4)
					movwf	ILED_AVERAGE_M
					movlw	HIGH ((vref_default-vref_table)*4)
					movwf	ILED_AVERAGE_H
					return

;	*	*	*	*	*	*	*	
;	ライトの状態をDEVICE_STATEに基づいて設定する。
;	*	*	*	*	*	*	*	
ctrl_state:		
					BANKSEL	0
					btfss	PIR1,TMR2IF
					return

					bcf		PIR1,TMR2IF
					clrwdt

					; SW_L, SW_R, SW_C の値を読み取ります。
					BANKSEL	CM1CON0
					bsf		CM1CON0,C1ON	; wake-up comparator
					clrw
					BANKSEL	PORTA
					btfss	SW_L
					bsf		WREG,BIT_SW_STATE_L
					btfss	SW_R
					bsf		WREG,BIT_SW_STATE_R
					BANKSEL	CM1CON0
					btfss	SW_C
					bsf		WREG,BIT_SW_STATE_C
					bcf		CM1CON0,C1ON	; shutdown comparator

					; チャタリング除去
					xorwf	SW_TRANSIENT,W	; W = changed SW mask
					andwf	SW_STATE,F	; erase unchanged bits
					xorwf	SW_TRANSIENT,F	; update changed bits
					xorlw	0xFF
					andwf	SW_TRANSIENT,W	; erase changed bits
					iorwf	SW_STATE,F

					; DEVICE_STATEに書かれた処理に分岐します。
					BANKSEL	0
					movf	DEVICE_STATE,W
					movwf	PCL

					org		0x100
;	*	*	*	*	*	*	*	
; デバイス制御用の有限状態機械の実装
;	*	*	*	*	*	*	*	

; 電源投入後、SW_Cを離すのを待っている
fsm_por_release_wait:	btfss	SW_STATE_C
					goto	transit_steady_and_return	; SW_Cを離すとsteadyへ遷移

					; 押されたまま1秒経過すると消灯カウンタを0に設定
					movf	SW_TIMER,F
					btfsc	STATUS,Z
					return			; すでに0になってる。
					decfsz	SW_TIMER,F
					return			; まだ0になってない。
					clrf	OFF_TIMER_L	; 今0になったところなので、OFF TIMERをクリア。
					clrf	OFF_TIMER_H
					movlw	BLINK_TIME
					subwf	TMR1H,F		; 連続ONになったという、応答を生成
					clrf	PORTC
					movlw	LP_TIME		; 連続ON受付後の長押しは1秒
					movwf	SW_TIMER
					movlw	LOW fsm_color_change_wait
					movwf	DEVICE_STATE
					return		

; SW_Cを離すのを待っている
fsm_color_change_wait:	call	off_timer_rewind	; ※ 消灯カウンタを初期値にもどす
					btfss	SW_STATE_C
					goto	transit_steady_and_return	; 1秒以内に離すとsteadyへ遷移

					; 押されたまま1秒経過するとLEDを切り替える
					decfsz	SW_TIMER,F
					return				; まだ0になってない。
					goto	change_led_color	; 今0になったところ

; SW_C, SW_L, SW_Rが押されるのを待っている
fsm_steady:			movlw	LP_TIME		; どの状態へ遷移するにも、長押し1秒？
					movwf	SW_TIMER

					btfsc	SW_STATE_C
					goto	steady_c1
					btfsc	SW_STATE_L
					goto	steady_l1
					btfsc	SW_STATE_R
					goto	steady_r1

steady_r0:			movf	OFF_TIMER_L,W
					iorwf	OFF_TIMER_H,W
					btfsc	STATUS,Z
					return			; off timer is not used

					movlw	-1		; decrement
					addwf	OFF_TIMER_L,F
					addwfc	OFF_TIMER_H,F

					movf	OFF_TIMER_L,W	; 消灯カウンタの1->0の遷移でpower_offへ遷移
					iorwf	OFF_TIMER_H,W
					btfss	STATUS,Z
					return		
					goto	power_off	; off timer is expired

steady_c1:			movlw	LOW fsm_power_off_wait
					movwf	DEVICE_STATE	; SW_Cが押されたときはpower_off_waitへ遷移
					return		

steady_l1:			movlw	LOW fsm_darken_wait1
					movwf	DEVICE_STATE	; SW_Lが押されたときは1段暗くしてdarken_wait1へ遷移
					goto	darken_led

steady_r1:			movlw	LOW fsm_brighten_wait1
					movwf	DEVICE_STATE	; SW_Rが押されたときは1段明るくしてbrighten_wait1へ遷移
					goto	brighten_led

; SW_Rが離されるのを待っている
fsm_brighten_wait1:	call	off_timer_rewind	; ※ 消灯カウンタを初期値にもどす
					btfss	SW_STATE_R
					goto	transit_steady_and_return	; SW_Rが離されたのでsteadyへ遷移

					; 押されたまま1秒経過すると1段明るくしてbrighten_wait2へ遷移
					decfsz	SW_TIMER,F
					return					; まだ0になってない。
					movlw	LOW fsm_brighten_wait2
					movwf	DEVICE_STATE
					goto	brighten_led_repeat		; 今0になったところ

; SW_Rが離されるのを待っている
fsm_brighten_wait2:	call	off_timer_rewind	; ※ 消灯カウンタを初期値にもどす
					btfss	SW_STATE_R
					goto	transit_steady_and_return	; SW_Rが離されたのでsteadyへ遷移

					; 押されたまま0.2秒経過すると1段明るくする
					decfsz	SW_TIMER,F
					return					; まだ0になってない。
					goto	brighten_led_repeat		; 今0になったところ

; SW_Lが離されるのを待っている
fsm_darken_wait1:	call	off_timer_rewind	; ※ 消灯カウンタを初期値にもどす
					btfss	SW_STATE_L
					goto	transit_steady_and_return	; SW_Lが離されたのでsteadyへ遷移

					; 押されたまま1秒経過すると1段暗くしてfsm_darken_wait2へ遷移
					decfsz	SW_TIMER,F
					return					; まだ0になってない。
					movlw	LOW fsm_darken_wait2
					movwf	DEVICE_STATE
					goto	darken_led_repeat		; 今0になったところ

; SW_Lが離されるのを待っている
fsm_darken_wait2:	call	off_timer_rewind	; ※ 消灯カウンタを初期値にもどす
					btfss	SW_STATE_L
					goto	transit_steady_and_return	; SW_Lが離されたときはsteadyへ遷移

					; 押されたまま0.2秒経過すると1段暗くする
					decfsz	SW_TIMER,F
					return					; まだ0になってない。
					goto	darken_led_repeat		; 今0になったところ

; SW_Cを離すのを待っている
fsm_power_off_wait:	btfss	SW_STATE_C
					goto	power_off	; 1秒以内に離すとpower_offへ遷移

					; 押されたまま1秒経過するとLEDを切り替えてfsm_color_change_waitへ遷移
					decfsz	SW_TIMER,F
					return					; まだ0になってない。
					movlw	LOW fsm_color_change_wait
					movwf	DEVICE_STATE
					goto	change_led_color		; 今0になったところ

; steadyへ遷移して、LEDの状態を変更することなく戻ります。
transit_steady_and_return:
					movlw	LOW fsm_steady
					movwf	DEVICE_STATE
					return		

; 消灯カウンタを初期値にもどす
;	0 なら 0 のまま
;	0 でなければ、OFF_TIME にする。
off_timer_rewind:	movf	OFF_TIMER_L,W
					iorwf	OFF_TIMER_H,W
					btfsc	STATUS,Z
					return			; 0ならばタイマーは使わないということで、そのまま
					movlw	LOW OFF_TIME
					movwf	OFF_TIMER_L
					movlw	HIGH OFF_TIME
					movwf	OFF_TIMER_H
					return

; 明るさインデックスは変えないで、LEDの色を変える。
change_led_color:	movlw	LP_TIME		; 色変更後の長押しは1秒
					movwf	SW_TIMER
					movlw	DISCHARGE_TIME
					subwf	TMR1H,F		; delay interrupt 
					clrf	PORTC
					call	dac_init		; 色を変えたときは電流を0から設定しなおす。
					movlw	LED_STATE_WHITE_MASK	; WHITE LED flag
					xorwf	LED_STATE,F
					goto	eeprom_update

; LEDを明るくする。
brighten_led_repeat: movlw	LP_TIME/8
					movwf	SW_TIMER
brighten_led:		incf	LED_STATE,W
					xorwf	LED_STATE,W
					andlw	LED_STATE_WHITE_MASK	; WHILE LED flag
					btfss	STATUS,Z
					return			; reached to upper limit
					incf	LED_STATE,F
					goto	eeprom_update

; LEDを暗くする。
darken_led_repeat:	movlw	LP_TIME/8
					movwf	SW_TIMER
darken_led:			decf	LED_STATE,W
					xorwf	LED_STATE,W
					andlw	LED_STATE_WHITE_MASK	; WHILE LED flag
					btfss	STATUS,Z
					return			; reached to lower limit
					decf	LED_STATE,F
					goto	eeprom_update

;	*	*	*	*	*	*	*	
; 電圧を制御するためにDACRなどを設定するためのLUT
;	*	*	*	*	*	*	*	
					org		0x180
vref_table:			retlw	FLAG_HI|0
					retlw	FLAG_HI|0
					retlw	FLAG_HI|0
					retlw	FLAG_HI|0
					retlw	FLAG_HI|0
					retlw	FLAG_HI|0
					retlw	FLAG_HI|0
					retlw	FLAG_HI|0
					retlw	FLAG_HI|0
					retlw	FLAG_HI|0
					retlw	FLAG_HI|0
					retlw	FLAG_HI|0
					retlw	FLAG_HI|0
					retlw	FLAG_HI|0
					retlw	FLAG_HI|0
					retlw	FLAG_HI|0
					retlw	FLAG_HI|0
					retlw	FLAG_HI|0
					retlw	FLAG_HI|0
					retlw	FLAG_HI|0
					retlw	FLAG_HI|0
					retlw	FLAG_HI|0	;			22 entry
					retlw	FLAG_HI|0	; Hi 4194.67
					retlw	FLAG_HI|1	; Hi 4165.06
					retlw	FLAG_HI|2	; Hi 4136.21
					retlw	FLAG_HI|3	; Hi 4108.05
					retlw	FLAG_HI|4	; Hi 4080.5
					retlw	FLAG_HI|5	; Hi 4053.52
					retlw	FLAG_HI|6	; Hi 4027.05
					retlw	FLAG_HI|7	; Hi 4001.03
					retlw	FLAG_HI|8	; Hi 3975.43
					retlw	FLAG_HI|9	; Hi 3950.18
					retlw	FLAG_HI|10	; Hi 3925.25
					retlw	FLAG_HI|11	; Hi 3900.6
					retlw	FLAG_HI|12	; Hi 3876.18
					retlw	FLAG_HI|13	; Hi 3851.95
					retlw	FLAG_HI|14	; Hi 3827.88
					retlw	FLAG_HI|15	; Hi 3803.91
					retlw	FLAG_HI|16	; Hi 3780.02
					retlw	FLAG_HI|17	; Hi 3756.17
					retlw	FLAG_HI|18	; Hi 3732.32
					retlw	FLAG_HI|19	; Hi 3708.42
					retlw	FLAG_HI|20	; Hi 3684.45
					retlw	FLAG_HI|21	; Hi 3660.37
					retlw	FLAG_HI|22	; Hi 3636.13
					retlw	FLAG_HI|23	; Hi 3611.69
					retlw	FLAG_HI|24	; Hi 3587.01
					retlw	FLAG_HI|25	; Hi 3562.06
					retlw	FLAG_HI|26	; Hi 3536.77
					retlw	FLAG_HI|27	; Hi 3511.12		28 entry
					retlw	FLAG_MID|7
					retlw	FLAG_MID|8	; Z 3491.43
					retlw	FLAG_MID|9	; Z 3466.18
					retlw	FLAG_MID|10	; Z 3441.25
					retlw	FLAG_MID|11	; Z 3416.6
					retlw	FLAG_MID|12	; Z 3392.18
					retlw	FLAG_MID|13	; Z 3367.95
					retlw	FLAG_MID|14	; Z 3343.88
					retlw	FLAG_MID|15	; Z 3319.91
					retlw	FLAG_MID|16	; Z 3296.02
					retlw	FLAG_MID|17	; Z 3272.17
					retlw	FLAG_MID|18	; Z 3248.32
					retlw	FLAG_MID|19	; Z 3224.42
					retlw	FLAG_MID|20	; Z 3200.45
					retlw	FLAG_MID|21	; Z 3176.37
					retlw	FLAG_MID|22	; Z 3152.13
					retlw	FLAG_MID|23	; Z 3127.69
					retlw	FLAG_MID|24	; Z 3103.01
					retlw	FLAG_MID|25	; Z 3078.06
					retlw	FLAG_MID|26	; Z 3052.77
					retlw	FLAG_MID|27	; Z 3027.12
					retlw	FLAG_MID|28	; Z 3001.05
					retlw	FLAG_MID|29
					retlw	FLAG_MID|30	;			24 entry
					retlw	FLAG_LOW|0	; Lo 2996.19
					retlw	FLAG_LOW|1	; Lo 2975.05
					retlw	FLAG_LOW|2	; Lo 2954.44
					retlw	FLAG_LOW|3	; Lo 2934.32
					retlw	FLAG_LOW|4	; Lo 2914.64
					retlw	FLAG_LOW|5	; Lo 2895.37
					retlw	FLAG_LOW|6	; Lo 2876.46
					retlw	FLAG_LOW|7	; Lo 2857.88
					retlw	FLAG_LOW|8	; Lo 2839.59
					retlw	FLAG_LOW|9	; Lo 2821.56
					retlw	FLAG_LOW|10	; Lo 2803.75
					retlw	FLAG_LOW|11	; Lo 2786.14
					retlw	FLAG_LOW|12	; Lo 2768.7
					retlw	FLAG_LOW|13	; Lo 2751.39
					retlw	FLAG_LOW|14	; Lo 2734.2
					retlw	FLAG_LOW|15	; Lo 2717.08
					retlw	FLAG_LOW|16	; Lo 2700.02
					retlw	FLAG_LOW|17	; Lo 2682.98
					retlw	FLAG_LOW|18	; Lo 2665.94
					retlw	FLAG_LOW|19	; Lo 2648.87
					retlw	FLAG_LOW|20	; Lo 2631.75
					retlw	FLAG_LOW|21	; Lo 2614.55
					retlw	FLAG_LOW|22	; Lo 2597.23
					retlw	FLAG_LOW|23	; Lo 2579.78
					retlw	FLAG_LOW|24	; Lo 2562.15
					retlw	FLAG_LOW|25	; Lo 2544.33
					retlw	FLAG_LOW|26	; Lo 2526.27
vref_default:		retlw	FLAG_LOW|27	; Lo 2507.94
					retlw	FLAG_LOW|28	; Lo 2489.32
					retlw	FLAG_LOW|29	; Lo 2470.36
					retlw	FLAG_LOW|30	; Lo 2451.02
					retlw	FLAG_LOW|31	; Lo 2431.26		32 entry
					retlw	FLAG_LOWEST|31	; Lo 2411.05		1 entry
					retlw	FLAG_LOWEST|31
					retlw	FLAG_LOWEST|31
					retlw	FLAG_LOWEST|31
					retlw	FLAG_LOWEST|31
					retlw	FLAG_LOWEST|31
					retlw	FLAG_LOWEST|31
					retlw	FLAG_LOWEST|31
					retlw	FLAG_LOWEST|31
					retlw	FLAG_LOWEST|31
					retlw	FLAG_LOWEST|31
					retlw	FLAG_LOWEST|31
					retlw	FLAG_LOWEST|31
					retlw	FLAG_LOWEST|31
					retlw	FLAG_LOWEST|31
					retlw	FLAG_LOWEST|31
					retlw	FLAG_LOWEST|31
					retlw	FLAG_LOWEST|31
					retlw	FLAG_LOWEST|31
					retlw	FLAG_LOWEST|31
					retlw	FLAG_LOWEST|31
					retlw	FLAG_LOWEST|31	;			21 entry

;	*	*	*	*	*	*	*	
; LEDの明るさを設定するためのLUT
;	*	*	*	*	*	*	*	
; 電流検出抵抗切替で10倍、電圧設定で20倍の範囲の電流を変化させることができる。
; SSL-LX5093SRCでは、距離300mmで0.1lxのとき、0.009cd必要。0.25cd@20mAのLEDでは、0.009/0.25*20=0.72mAになる。
; 30mA流すと、0.25/0.3^2*30/20=4.2lxになる。実測で4.9lxだけど、1個あたりでは半分しか出てない。測定誤差？
; 2個使用時は0.1lxにするためには1個当たり0.36mA、30mAを２個に流せば8.4lxになる。
; C503では、3個を30mAで点灯し、300mmの距離での照度は24/0.3^2*90/20=1200lxとなる。実測で1100lxくらいだった。
;	1個を0.3mAで点灯し、300mmの距離での照度は24/0.3^2*0.3/20=4lxとなる。実測で3.7lxくらいだった。
COE_I_LO			equ		65536/FVR_mV*LED_IVC_LO_mOHM/1000	; for 0.16 fxp
COE_I_HI			equ		65536/FVR_mV*LED_IVC_HI_mOHM/1000	; for 0.16 fxp

#include current.inc

; led_table[][0]	PORTC
; led_table[][1]	LOW byte of desired current to FS in 0.16fxp
; led_table[][2]	HIGH byte of desired current to FS in 0.16fxp
; ADCには±2LSBの誤差があるので、最小設定時に最小値と最大値で２倍にするには、
; 最小設定を6LSBにする。
					org		0x200
led_table:
RED_0:				retlw	PORTC_RED2_LO
					retlw	LOW  (LED_R_I0*COE_I_LO/1000)
					retlw	HIGH (LED_R_I0*COE_I_LO/1000)
RED_1:				retlw	PORTC_RED2_LO
					retlw	LOW  (LED_R_I1*COE_I_LO/1000)
					retlw	HIGH (LED_R_I1*COE_I_LO/1000)
RED_2:				retlw	PORTC_RED2_LO
					retlw	LOW  (LED_R_I2*COE_I_LO/1000)
					retlw	HIGH (LED_R_I2*COE_I_LO/1000)
RED_3:				retlw	PORTC_RED2_LO
					retlw	LOW  (LED_R_I3*COE_I_LO/1000)
					retlw	HIGH (LED_R_I3*COE_I_LO/1000)
RED_4:				retlw	PORTC_RED2_LO
					retlw	LOW  (LED_R_I4*COE_I_LO/1000)
					retlw	HIGH (LED_R_I4*COE_I_LO/1000)
RED_5:				retlw	PORTC_RED2_LO
					retlw	LOW  (LED_R_I5*COE_I_LO/1000)
					retlw	HIGH (LED_R_I5*COE_I_LO/1000)
RED_6:				retlw	PORTC_RED2_HI
					retlw	LOW  (LED_R_I6*COE_I_HI/1000)
					retlw	HIGH (LED_R_I6*COE_I_HI/1000)
RED_7:				retlw	PORTC_RED2_HI
					retlw	LOW  (LED_R_I7*COE_I_HI/1000)
					retlw	HIGH (LED_R_I7*COE_I_HI/1000)
RED_8:				retlw	PORTC_RED2_HI
					retlw	LOW  (LED_R_I8*COE_I_HI/1000)
					retlw	HIGH (LED_R_I8*COE_I_HI/1000)
RED_9:				retlw	PORTC_RED2_HI
					retlw	LOW  (LED_R_I9*COE_I_HI/1000)
					retlw	HIGH (LED_R_I9*COE_I_HI/1000)
RED_10:				retlw	PORTC_RED2_HI
					retlw	LOW  (LED_R_I10*COE_I_HI/1000)
					retlw	HIGH (LED_R_I10*COE_I_HI/1000)
RED_11:				retlw	PORTC_RED2_HI
					retlw	LOW  (LED_R_I11*COE_I_HI/1000)
					retlw	HIGH (LED_R_I11*COE_I_HI/1000)
RED_12:				retlw	PORTC_RED2_HI
					retlw	LOW  (LED_R_I12*COE_I_HI/1000)
					retlw	HIGH (LED_R_I12*COE_I_HI/1000)
RED_13:				retlw	PORTC_RED2_HI
					retlw	LOW  (LED_R_I13*COE_I_HI/1000)
					retlw	HIGH (LED_R_I13*COE_I_HI/1000)
RED_14:				retlw	PORTC_RED2_HI
					retlw	LOW  (LED_R_I14*COE_I_HI/1000)
					retlw	HIGH (LED_R_I14*COE_I_HI/1000)
RED_15:				retlw	PORTC_RED2_HI
					retlw	LOW  (LED_R_I15*COE_I_HI/1000)
					retlw	HIGH (LED_R_I15*COE_I_HI/1000)
WHITE_0:			retlw	PORTC_WHITE1_LO
					retlw	LOW  (LED_W_I0*COE_I_LO/1000)
					retlw	HIGH (LED_W_I0*COE_I_LO/1000)
WHITE_1:			retlw	PORTC_WHITE1_LO
					retlw	LOW  (LED_W_I1*COE_I_LO/1000)
					retlw	HIGH (LED_W_I1*COE_I_LO/1000)
WHITE_2:			retlw	PORTC_WHITE1_LO
					retlw	LOW  (LED_W_I2*COE_I_LO/1000)
					retlw	HIGH (LED_W_I2*COE_I_LO/1000)
WHITE_3:			retlw	PORTC_WHITE1_LO
					retlw	LOW  (LED_W_I3*COE_I_LO/1000)
					retlw	HIGH (LED_W_I3*COE_I_LO/1000)
WHITE_4:			retlw	PORTC_WHITE1_LO
					retlw	LOW  (LED_W_I4*COE_I_LO/1000)
					retlw	HIGH (LED_W_I4*COE_I_LO/1000)
WHITE_5:			retlw	PORTC_WHITE1_LO
					retlw	LOW  (LED_W_I5*COE_I_LO/1000)
					retlw	HIGH (LED_W_I5*COE_I_LO/1000)
WHITE_6:			retlw	PORTC_WHITE1_LO
					retlw	LOW  (LED_W_I6*COE_I_LO/1000)
					retlw	HIGH (LED_W_I6*COE_I_LO/1000)
WHITE_7:			retlw	PORTC_WHITE1_HI
					retlw	LOW  (LED_W_I7*COE_I_HI/1000)
					retlw	HIGH (LED_W_I7*COE_I_HI/1000)
WHITE_8:			retlw	PORTC_WHITE1_HI
					retlw	LOW  (LED_W_I8*COE_I_HI/1000)
					retlw	HIGH (LED_W_I8*COE_I_HI/1000)
WHITE_9:			retlw	PORTC_WHITE1_HI
					retlw	LOW  (LED_W_I9*COE_I_HI/1000)
					retlw	HIGH (LED_W_I9*COE_I_HI/1000)
WHITE_10:			retlw	PORTC_WHITE1_HI
					retlw	LOW  (LED_W_I10*COE_I_HI/1000)
					retlw	HIGH (LED_W_I10*COE_I_HI/1000)
WHITE_11:			retlw	PORTC_WHITE1_HI
					retlw	LOW  (LED_W_I11*COE_I_HI/1000)
					retlw	HIGH (LED_W_I11*COE_I_HI/1000)
WHITE_12:			retlw	PORTC_WHITE3_HI
					retlw	LOW  (LED_W_I12/3*COE_I_HI/1000)
					retlw	HIGH (LED_W_I12/3*COE_I_HI/1000)
WHITE_13:			retlw	PORTC_WHITE3_HI
					retlw	LOW  (LED_W_I13/3*COE_I_HI/1000)
					retlw	HIGH (LED_W_I13/3*COE_I_HI/1000)
WHITE_14:			retlw	PORTC_WHITE3_HI
					retlw	LOW  (LED_W_I14/3*COE_I_HI/1000)
					retlw	HIGH (LED_W_I14/3*COE_I_HI/1000)
WHITE_15:			retlw	PORTC_WHITE3_HI
					retlw	LOW  (LED_W_I15/3*COE_I_HI/1000)
					retlw	HIGH (LED_W_I15/3*COE_I_HI/1000)

#if 0
iv_curve			equ		0x0680

acquire_iv:
					BANKSEL	EECON1
					bsf		EECON1,EEPGD
					bcf		EECON1,CFGS
					movlw	HIGH iv_curve
					movwf	EEADRH
					movlw	LOW iv_curve
					movwf	EEADRL

					bsf		EECON1,RD
					nop
					nop
					movf	EEDATL,W
					xorlw	0xFF
					btfss	STATUS,Z
					goto	abort_calibration

					bsf		EECON1,WREN
					bsf		EECON1,LWLO

					BANKSEL	ADCON0
					bsf		ADCON1,7	; right justified

					BANKSEL	DACCON0
					bsf		DACCON0,DACEN

; white LED
					BANKSEL	0
					movlw	PORTC_WHITE1_LO
					movwf	PORTC
;	low voltage, low current
					BANKSEL	LATA
					bsf		PIN_VREF_LO	; low/mid
					BANKSEL	TRISA
					bcf		TRIS_VREF	; low voltage range
					call	get_iv_curve

;	mid voltage, low current
					BANKSEL	TRISA
					bsf		TRIS_VREF	; mid voltage range
					call	get_iv_curve

					BANKSEL	0
					movlw	PORTC_WHITE1_HI
					movwf	PORTC
;	low voltage, high current
					BANKSEL	TRISA
					bcf		TRIS_VREF	; low voltage range
					call	wait10ms
					call	get_iv_curve

;	mid voltage, high current
					BANKSEL	TRISA
					bsf		TRIS_VREF	; mid voltage range
					call	get_iv_curve

;	high voltage, high current
					BANKSEL	LATA
					bcf		PIN_VREF_LO	; mid/high
					BANKSEL	TRISA
					bcf		TRIS_VREF	; high voltage range
					call	get_iv_curve

; red LED
					BANKSEL	0
					movlw	PORTC_RED2_LO
					movwf	PORTC
;	low voltage, low current
					BANKSEL	LATA
					bsf		PIN_VREF_LO	; low/mid
					call	wait10ms
					call	get_iv_curve

;	mid voltage, low current
					BANKSEL	TRISA
					bsf		TRIS_VREF	; mid voltage range
					call	get_iv_curve

;	high voltage, low current
					BANKSEL	LATA
					bcf		PIN_VREF_LO	; mid/high
					BANKSEL	TRISA
					bcf		TRIS_VREF	; high voltage range
					call	get_iv_curve

					BANKSEL	0
					movlw	PORTC_RED2_HI
					movwf	PORTC
;	mid voltage, high current
					BANKSEL	TRISA
					bsf		TRIS_VREF	; mid voltage range
					call	wait10ms
					call	get_iv_curve

;	high voltage, high current
					BANKSEL	TRISA
					bcf		TRIS_VREF	; high voltage range
					call	get_iv_curve

; Resister
					BANKSEL	0
					clrf	PORTC		; low current, no LED
					BANKSEL	TRISA
					bcf		TRIS_CALIB	; sourcing current from RA5 to I-V resister
;	low voltage, low current
					BANKSEL	LATA
					bsf		PIN_VREF_LO	; low/mid
					call	wait10ms
					call	get_iv_curve

;	mid voltage, low current
					BANKSEL	TRISA
					bsf		TRIS_VREF	; mid voltage range
					call	get_iv_curve

;	high voltage, low current
					BANKSEL	LATA
					bcf		PIN_VREF_LO	; mid/high
					BANKSEL	TRISA
					bcf		TRIS_VREF	; high voltage range
					call	get_iv_curve

					BANKSEL	TRISA
					bsf		TRIS_CALIB	; done

done_calibration:
					call 	dac_init

					BANKSEL	ADCON0
					bcf		ADCON1,7	; left justified

					call	wait10ms

abort_calibration:
					BANKSEL	EECON1
					clrf	EEADRL
					clrf	EEADRH
					bcf		EECON1,WREN
					bcf		EECON1,EEPGD

					BANKSEL	0
					return

get_iv_curve:
					BANKSEL	DACCON0
					movlw	-1
					movwf	DACCON1
					call	wait10ms
					call	wait10ms	; wait for settling DC-DC converter
					movlw	32
					movwf	W1
acquire_loop:		movlw	16
					movwf	W2
					clrf	ILED_AVERAGE_L
					clrf	ILED_AVERAGE_H
average_loop:		call	accumulate
					decfsz	W2,F
					goto	average_loop

					BANKSEL	DACCON1
					decf	DACCON1,F

					call	flash_write_iled

					decfsz	W1,F
					goto	acquire_loop
					return

accumulate:			goto	$+1
					goto	$+1
					BANKSEL	ADCON0
					bsf		ADCON0,GO
					btfsc	ADCON0,GO
					goto	$-1
					movf	ADRESL,W
					addwf	ILED_AVERAGE_L,F
					movf	ADRESH,W
					addwfc	ILED_AVERAGE_H,F
					return

; write average current of LED into flash
flash_write_iled:
					BANKSEL	EECON1
					movf	ILED_AVERAGE_L,W
					movwf	EEDATL
					movf	ILED_AVERAGE_H,W
					movwf	EEDATH

					movf	EEADRL,W
					xorlw	0x0F
					andlw	0x0F
					btfsc	STATUS,Z
					bcf		EECON1,LWLO

					movlw	0x55		; Unlock write
					movwf	EECON2
					movlw	0xAA
					movwf	EECON2
					bsf		EECON1,WR 	; Start the write
					nop
					nop

					movlw	1
					addwf	EEADRL,F
					movlw	0
					addwfc	EEADRH,F
					movf	EEADRL,W
					andlw	0x0F
					btfsc	STATUS,Z
					bsf		EECON1,LWLO
					return
#endif

offset_data			equ		0x20
; ADC reading - offset = true value
; 0018-0020 くらいにしかならない。1LSB以下。20msほどなので、毎回実行する。
calibration:
; 最低電圧へ
					BANKSEL	TRISA
					bcf		TRIS_CALIB	; sourcing current from RA5 to I-V resister

					movlw	HIGH calib_table
					movwf	FSR0H
					movlw	offset_data
					movwf	FSR1L
					clrf	FSR1H

					call	wait10ms

; 最低電圧から最高電圧へ動かして、1LSB変化したときの誤差
					BANKSEL	ADCON0
					bsf		ADCON0,GO
					btfsc	ADCON0,GO
					goto	$-1
					BANKSEL	DACCON0
					bsf		DACCON0,DACEN
calib_loop1:
					BANKSEL	ADCON0
					movf	ADRESL,W
					movwf	W1
					movf	ADRESH,W
					movwf	W2
calib_loop2:
					call	wait100us	; ADC settling time
					BANKSEL	ADCON0
					bsf		ADCON0,GO
					BANKSEL	DACCON0
					decf	DACCON1,F
					movf	DACCON1,F
					btfsc	STATUS,Z
					goto	calib_exit
					BANKSEL	ADCON0
					btfsc	ADCON0,GO
					goto	$-1

					movf	ADRESL,W
					subwf	W1,W
					movf	ADRESH,W
					subwfb	W2,W
					btfss	WREG,7		; (initial - ADRES) < 0
					goto	calib_loop2

					BANKSEL	DACCON0
					incf	DACCON1,W
					lslf	WREG,F
					movwf	FSR0L
					moviw	FSR0++		; initial - ((previous true value + current true value)/2 - 0.5LSB)
					subwf	W1,F
					moviw	FSR0++
					subwfb	W2,F
;;
					movf	W1,W
					movwi	FSR1++
					movf	W2,W
					movwi	FSR1++
					goto	calib_loop1

calib_exit:
					BANKSEL	DACCON0
					movlw	-1
					movwf	DACCON1

					movlw	offset_data
					movwf	FSR1L

					moviw	FSR1++
					movwf	ADC_OFFSET_L
					moviw	FSR1++
					movwf	ADC_OFFSET_M

					moviw	FSR1++
					addwf	ADC_OFFSET_L,F
					moviw	FSR1++
					addwfc	ADC_OFFSET_M,F

					moviw	FSR1++
					addwf	ADC_OFFSET_L,F
					moviw	FSR1++
					addwfc	ADC_OFFSET_M,F

					moviw	FSR1++
					addwf	ADC_OFFSET_L,F
					moviw	FSR1++
					addwfc	ADC_OFFSET_M,F

					asrf	ADC_OFFSET_M,F
					rrf		ADC_OFFSET_L,F
					asrf	ADC_OFFSET_M,F
					rrf		ADC_OFFSET_L,F
					movlw	-1
					movwf	ADC_OFFSET_H
					btfss	ADC_OFFSET_M,7
					clrf	ADC_OFFSET_H

;;
					call	wait6ms
					BANKSEL	TRISA
					bsf		TRIS_CALIB	; set RA5 to Hi-Z
					return

wait100us:			movlw	16
					decfsz	WREG,F
					goto	$-1
					return

wait2ms:			movlw	200
					goto	$+1
					decfsz	WREG,F
					goto	$-2
					return

wait10ms:			call	wait2ms
wait8ms:			call	wait2ms
wait6ms:			call	wait2ms
					call	wait2ms
					goto	wait2ms

					org		0x400
COE_CALIB			equ		65536/FVR_mV*LED_IVC_LO_mOHM*10/(CALIBRATION_R_kOHM*10000+LED_IVC_LO_mOHM/100)	; for 0.16 fxp
calib_table:		retlw	LOW  ((2975+2996)*COE_CALIB/2000-32)
					retlw	HIGH ((2975+2996)*COE_CALIB/2000-32)
					retlw	LOW  ((2954+2975)*COE_CALIB/2000-32)
					retlw	HIGH ((2954+2975)*COE_CALIB/2000-32)
					retlw	LOW  ((2934+2954)*COE_CALIB/2000-32)
					retlw	HIGH ((2934+2954)*COE_CALIB/2000-32)
					retlw	LOW  ((2915+2934)*COE_CALIB/2000-32)
					retlw	HIGH ((2915+2934)*COE_CALIB/2000-32)
					retlw	LOW  ((2895+2915)*COE_CALIB/2000-32)
					retlw	HIGH ((2895+2915)*COE_CALIB/2000-32)
					retlw	LOW  ((2876+2895)*COE_CALIB/2000-32)
					retlw	HIGH ((2876+2895)*COE_CALIB/2000-32)
					retlw	LOW  ((2858+2876)*COE_CALIB/2000-32)
					retlw	HIGH ((2858+2876)*COE_CALIB/2000-32)
					retlw	LOW  ((2840+2858)*COE_CALIB/2000-32)
					retlw	HIGH ((2840+2858)*COE_CALIB/2000-32)
					retlw	LOW  ((2822+2840)*COE_CALIB/2000-32)
					retlw	HIGH ((2822+2840)*COE_CALIB/2000-32)
					retlw	LOW  ((2804+2822)*COE_CALIB/2000-32)
					retlw	HIGH ((2804+2822)*COE_CALIB/2000-32)
					retlw	LOW  ((2786+2804)*COE_CALIB/2000-32)
					retlw	HIGH ((2786+2804)*COE_CALIB/2000-32)
					retlw	LOW  ((2769+2786)*COE_CALIB/2000-32)
					retlw	HIGH ((2769+2786)*COE_CALIB/2000-32)
					retlw	LOW  ((2751+2769)*COE_CALIB/2000-32)
					retlw	HIGH ((2751+2769)*COE_CALIB/2000-32)
					retlw	LOW  ((2734+2751)*COE_CALIB/2000-32)
					retlw	HIGH ((2734+2751)*COE_CALIB/2000-32)
					retlw	LOW  ((2717+2734)*COE_CALIB/2000-32)
					retlw	HIGH ((2717+2734)*COE_CALIB/2000-32)
					retlw	LOW  ((2700+2717)*COE_CALIB/2000-32)
					retlw	HIGH ((2700+2717)*COE_CALIB/2000-32)
					retlw	LOW  ((2683+2700)*COE_CALIB/2000-32)
					retlw	HIGH ((2683+2700)*COE_CALIB/2000-32)
					retlw	LOW  ((2666+2683)*COE_CALIB/2000-32)
					retlw	HIGH ((2666+2683)*COE_CALIB/2000-32)
					retlw	LOW  ((2649+2666)*COE_CALIB/2000-32)
					retlw	HIGH ((2649+2666)*COE_CALIB/2000-32)
					retlw	LOW  ((2632+2649)*COE_CALIB/2000-32)
					retlw	HIGH ((2632+2649)*COE_CALIB/2000-32)
					retlw	LOW  ((2615+2632)*COE_CALIB/2000-32)
					retlw	HIGH ((2615+2632)*COE_CALIB/2000-32)
					retlw	LOW  ((2597+2615)*COE_CALIB/2000-32)
					retlw	HIGH ((2597+2615)*COE_CALIB/2000-32)
					retlw	LOW  ((2580+2597)*COE_CALIB/2000-32)
					retlw	HIGH ((2580+2597)*COE_CALIB/2000-32)
					retlw	LOW  ((2562+2580)*COE_CALIB/2000-32)
					retlw	HIGH ((2562+2580)*COE_CALIB/2000-32)
					retlw	LOW  ((2544+2562)*COE_CALIB/2000-32)
					retlw	HIGH ((2544+2562)*COE_CALIB/2000-32)
					retlw	LOW  ((2526+2544)*COE_CALIB/2000-32)
					retlw	HIGH ((2526+2544)*COE_CALIB/2000-32)
					retlw	LOW  ((2508+2526)*COE_CALIB/2000-32)
					retlw	HIGH ((2508+2526)*COE_CALIB/2000-32)
					retlw	LOW  ((2489+2508)*COE_CALIB/2000-32)
					retlw	HIGH ((2489+2508)*COE_CALIB/2000-32)
					retlw	LOW  ((2470+2489)*COE_CALIB/2000-32)
					retlw	HIGH ((2470+2489)*COE_CALIB/2000-32)
					retlw	LOW  ((2451+2470)*COE_CALIB/2000-32)
					retlw	HIGH ((2451+2470)*COE_CALIB/2000-32)
					retlw	LOW  ((2431+2451)*COE_CALIB/2000-32)
					retlw	HIGH ((2431+2451)*COE_CALIB/2000-32)
					retlw	LOW  ((2411+2431)*COE_CALIB/2000-32)
					retlw	HIGH ((2411+2431)*COE_CALIB/2000-32)

					end

