use Digest::CRC qw(crc16) ;
use Socket ;
use Win32::SerialPort;

sub dbgComInit
{
	my $com_port = $_[0] ;
	$com_port->error_msg(1);            # use built-in error messages
	$com_port->user_msg(1);
	
	$com_port->databits(8);
	$com_port->baudrate(115200);
	$com_port->parity("none");
	$com_port->stopbits(1);
	$com_port->handshake("none");
	$com_port->buffers(4096,4096) ;
	
	$com_port->read_interval(1);    # max time between read char (milliseconds)
	$com_port->read_char_time(1);     # avg time between read char
	$com_port->read_const_time(3);  # total = (avg * bytes) + const
#	$com_port->write_char_time(1);
#	$com_port->write_const_time(100);

	$com_port->write_settings || die "Couldn't write settings\n";
}



my $MODEM_SOH = 0x01 ;        #数据块起始字符 
my $MODEM_STX = 0x02 ;
my $MODEM_EOT = 0x04 ;
my $MODEM_ACK = 0x06 ;
my $MODEM_NAK = 0x15 ;
my $MODEM_CAN = 0x18 ;
my $MODEM_C   = 0x43 ;

my $MODEM_SEGMENT_LEN_1024 = 1024 ;
my $MODEM_SEGMENT_LEN_128 = 128 ;

my $STS_IDLE = 0 ;
my $STS_Wait4StartACK = 1 ;
my $STS_Wait4Start = 2 ;
my $STS_Transfering_Wait4ACK = 3 ;
my $STS_Wait4EOT_ACK = 4 ;
my $STS_WaitAtEOT4C = 5 ;
my $STS_Wait4Zero_ACK = 6 ;
my $STS_Wait4EOT_NACK = 7 ;

my @state_name = ("IDLE" , "Wait4StartACK" , "Wait4Start" , "Transfering_Wait4ACK" , "Wait4EOT_ACK" , "WaitAtEOT4C" , "Wait4Zero_ACK" ) ;

my $current_sts = $STS_IDLE ;
my $transfer_no = 0 ;
my $seg_buf ;

my $com ;

my $filename ;
my $filesize ;
my $round_finish = 0 ;
my $progress_str ;

#force the realtime print
$|=1 ;

# parameters:
# buf 
# len
sub ym_crc16
{  
  my $crc = 0;  
  my $j = 0 ;
  my @buf = unpack("C$_[1]" ,$_[0]) ;
  my $count = $_[1] ;

  while($count-- > 0) {  
    $crc = $crc ^ $buf[$j++] << 8;  

    for ($i=0; $i<8; $i++) 
	{  
      if ($crc & 0x8000) 
	  {  
        $crc = $crc << 1 ^ 0x1021;  
      } 
	  else 
	  {  
        $crc = $crc << 1;  
      }  
    }  
  }  
  ((($crc & 0x00ff) << 8) | (($crc & 0xff00) >> 8)) ;  
}

sub TEST_UART_Send
{
	$com->write($_[0]) ;
=nobufprint
	print unpack("H*" ,$_[0]) ;
	print "\n" ;
=cut
}

my $sent_bytes = 0 ;
#parameters :
# @file_buf -- pointer
sub getNextFileSeg
{
	my $buf ;
	my $len = read DATA ,$buf ,$MODEM_SEGMENT_LEN_1024 ;
	$sent_bytes += $len ;
#	print "++$len\n" ;
	($buf ,$len) ;
}

sub printSendProgress
{
	my $progress_percent = (100*$sent_bytes)/$filesize ;
	printf "\b" x length($progress_str) ;
	$progress_str = sprintf "%%%d" ,$progress_percent ;
	printf "$progress_str" ;
}

sub getTransferNo
{
	if ($transfer_no > 255) 
	{
		$transfer_no = 0 ;
	}

	$transfer_no++ ;
}

sub buma
{
	255 - $_[0]  ;
}

#parameters:
# file name
# file size
sub action_send_SOH
{
	my $filename = $_[0] ;	
	my $filesize = $_[1] ;	
	my $tmp_crc16 = 0 ;
	my $filesize_str = sprintf "%d" ,$filesize ;
	my $nu = getTransferNo() ;
	my $padding_size = 128 - length($filename) -  1 - length($filesize_str);

=ctaa
	$buf = pack("A*CA*C$padding_size" ,$filename ,0 ,$filesize_str ,0) ;
	$tmp_crc16 = ym_crc16($buf ,128) ;
	printf "crc %04x \n" ,$tmp_crc16 ;
	$seg_buf = pack("CCCC128n" ,$MODEM_SOH ,$num ,buma($num) ,unpack("C128" ,$buf),$tmp_crc16) ;
=cut

	$padding_size = 128 - length($filename) -  1 ;

	$buf = pack("A*CC$padding_size" ,$filename ,0 ,0) ;
	$tmp_crc16 = ym_crc16($buf ,128) ;
#	printf "crc %04x \n" ,$tmp_crc16 ;
	$seg_buf = pack("CCCC128n" ,$MODEM_SOH ,$num ,buma($num) ,unpack("C128" ,$buf),$tmp_crc16) ;

	TEST_UART_Send($seg_buf) ;
}

sub action_send_EOT
{
	$seg_buf = pack("C" ,$MODEM_EOT) ;
	TEST_UART_Send($seg_buf) ;
}

sub action_send_finishZero
{
	my $num = 0 ;
	$buf = pack("C128" ,0) ;
	$seg_buf = pack("CCCC128n" ,$MODEM_SOH ,$num ,buma($num) ,unpack("C128" ,$buf),ym_crc16($buf ,128)) ;
	TEST_UART_Send($seg_buf) ;
}

#parameters:
# file_buf
# len
sub action_send_fileSegment
{
	my $data_buf = $_[0] ;
	my $data_len = $_[1] ;
	my $seg_len = ($data_len > $MODEM_SEGMENT_LEN_128) ? $MODEM_SEGMENT_LEN_1024 : $MODEM_SEGMENT_LEN_128 ;
	my $head_indicator = ($data_len > $MODEM_SEGMENT_LEN_128) ? $MODEM_STX : $MODEM_SOH ;

	my $padding_size = $seg_len - $data_len ;
	my $num = getTransferNo() ;
	my $tmp_crc16 = 0 ;

	#construct data
	if ($seg_len == $data_len)
	{
		$buf = $data_buf ;
	}
	else
	{
		$buf = pack("C$data_len"."C$padding_size" ,unpack("C$data_len" ,$data_buf),0) ;
	}

	$tmp_crc16 = ym_crc16($buf ,$seg_len) ;

=noprint
	print "\nSeqNo : $transfer_no , data len : $data_len ,fragment len : $seg_len padding : $padding_size " ;
	printf "%04x \n" ,$tmp_crc16 ;
=cut

	$seg_buf = pack("CCCC".$seg_len."n" ,$head_indicator ,$num ,buma($num) ,unpack("C$seg_len" ,$buf),$tmp_crc16) ;
	TEST_UART_Send($seg_buf) ;
}

sub trigger_recv_C
{
	if ($STS_IDLE == $current_sts)
	{
		action_send_SOH($filename ,$filesize) ;

		$current_sts = $STS_Wait4StartACK ;
	}
	elsif ($STS_Transfering_Wait4ACK == $current_sts)
	{
		my ($file_buf ,$file_len)  = getNextFileSeg() ;
		if (0 == $file_len)
		{
			action_send_EOT() ;

			$current_sts = $STS_Wait4EOT_ACK ;
		}
		else
		{
			action_send_fileSegment($file_buf ,$file_len) ;
		}
	}
	elsif ($STS_Wait4Start == $current_sts)
	{
		my ($file_buf ,$file_len)  = getNextFileSeg() ;
		action_send_fileSegment($file_buf ,$file_len) ;
		$current_sts = $STS_Transfering_Wait4ACK ;
	}
	elsif ($STS_WaitAtEOT4C == $current_sts)
	{
		action_send_finishZero() ;
		$current_sts = $STS_Wait4Zero_ACK;
	}
}

sub trigger_recv_ACK
{
	if ($STS_Wait4StartACK == $current_sts)
	{
		$current_sts = $STS_Wait4Start ;
	}
	elsif ($STS_Wait4EOT_ACK == $current_sts)
	{
		$current_sts = $STS_WaitAtEOT4C ;
	}
	elsif ($STS_Wait4Zero_ACK == $current_sts)
	{
		$current_sts = $STS_IDLE ;
		$round_finish = 1 ;
	}
}

sub trigger_recv_NCK
{
	TEST_UART_Send($seg_buf) ;
}

sub trigger_recv_NAK
{
	if ($STS_Wait4EOT_NACK == $current_sts)
	{
		action_send_EOT() ;
		$current_sts = $STS_Wait4EOT_ACK ;
	}
}

my $port_name = $ARGV[0] ;
my $filepath = $ARGV[1] ;

if (! -e $filepath) 
{
	print "$filepath not found\n" ;
	return ;
}

$com = new Win32::SerialPort (uc $port_name) || die "Can't open $port_name: $^E\n";    # $quiet is optional
dbgComInit($com) ;

open DATA ,'<' ,$filepath or die "open $filepath failed\n" ;
binmode DATA ;

$filename = $filepath ;
$filename =~ s/^.*\\// ;
@file_args = stat($filepath) ;
$filesize = $file_args[7] ;

printf "$filename ,$filesize bytes -- " ;

$current_sts = $STS_IDLE ;
$tmp_sts = 100 ;
$com->purge_rx ;

while(1)
{
	my ($count_in, $tmpa) = $com->read(4096);
	$com->purge_rx ;

	next if (0 == $count_in) ;

#	printf "Raw ". unpack("C$count_in" ,$tmpa) ."\n"  ;
	$ch_str = unpack("C$count_in" ,$tmpa) ;

	if ($current_sts != $tmp_sts)
	{
#		print "\nstate : $state_name[$current_sts]\n" ;
		$tmp_sts = $current_sts ;
	}

	if ($MODEM_ACK == $ch_str)
	{
#		print "Recv : ACK\n" ;
		trigger_recv_ACK() ;
	}
	elsif ($MODEM_NAK == $ch_str)
	{
#		print "Recv : NAK\n" ;
		trigger_recv_NCK() ;
	}
	elsif ($MODEM_C == $ch_str)
	{
#		print "Recv : C\n" ;
		trigger_recv_C() ;
	}
	elsif ($MODEM_CAN == $ch_str)
	{
#		print "Recv : CAN\n" ;
		trigger_recv_NCK() ;
	}
	elsif ($MODEM_NAK == $ch_str)
	{
#		print "Recv : NAK\n" ;
		trigger_recv_NAK() ;
	}
	last if ($round_finish) ;

	printSendProgress() ;
}

#printf "\nYMODEM Send $filepath done !!\n" ;

RETURN_FLAG:
close DATA ;
$com->close ;
