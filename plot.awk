
# awk -W non-decimal-data -f plot.awk current.TXT > current.csv
BEGIN {
	offset=0x680;
	r1=330.0;
	r2=470.0;
	vref = 1210.0;
	fvr=2048.0;
	i_vref=vref*(1/r1+1/r2);
	r_iv_high=8.2;
	r_iv_low=75+r_iv_high;
}
function low(dac) {
	i_fvr=(vref - fvr*dac/32.0)/(r1+r2);
	return (i_vref+i_fvr)/(1/r1+1/(r1+r2)) + vref;
}
function mid(dac) {
	i_fvr=(vref - fvr*dac/32.0)/(r1+r2);
	return (i_vref+i_fvr)*r1 + vref;
}
function high(dac) {
	i_fvr=(vref - fvr*dac/32.0)/(r1+r2);
	return (i_vref+i_fvr+vref/(r1+r2))*r1 + vref;
}
{
	s=strtonum("0x"$2)-offset;
	block=s/32;
	dac=(31-s%32);
	v=strtonum("0x"$3)/16.0*2.048;
	if(block<1){
		print low(dac)"\t"v/r_iv_low;
	} else if(block < 2){
		print mid(dac)"\t"v/r_iv_low;
	} else if(block < 3){
		print low(dac)"\t"v/r_iv_high;
	} else if(block < 4){
		print mid(dac)"\t"v/r_iv_high;
	} else if(block < 5){
		print high(dac)"\t"v/r_iv_high;
	} else if(block < 6){
		print low(dac)"\t"v/r_iv_low;
	} else if(block < 7){
		print mid(dac)"\t"v/r_iv_low;
	} else if(block < 8){
		print high(dac)"\t"v/r_iv_low;
	} else if(block < 9){
		print mid(dac)"\t"v/r_iv_high;
	} else if(block < 10){
		print high(dac)"\t"v/r_iv_high;
	}
	if(dac==0) print "\n";
}

