package FHEM::TadoDevice;

use strict;
use warnings;
use Scalar::Util qw(looks_like_number);
use GPUtils qw(GP_Import GP_Export);

## Import der FHEM Funktionen
#-- Run before package compilation
BEGIN {
    # Import from main context
    GP_Import(
        qw(
          Log3
		  Log
		  readingFnAttributes
          readingsBeginUpdate
          readingsEndUpdate
          readingsBulkUpdate
          readingsSingleUpdate
          readingsDelete
          ReadingsVal
          InternalVal
		  AssignIoPort
		  CommandAttr
		  AttrVal
          defs
		  modules
		  IOWrite
          )
    );
}

#-- Export to main context with different name
GP_Export(
    qw(
      Initialize
      )
);



my %TadoDevice_gets = (
update	=> " "
);

my %TadoDevice_zone_sets = (
automatic             => ' ',
off       	          => " ",
'temperature'	          => " ",
'temperature-for-60'	=> " ",
'temperature-for-90'	=> " ",
'temperature-for-120'	=> " ",
'temperature-for-180'	=> " ",
'temperature-for-240'	=> " ",
'temperature-for-300'	=> " "
);

my %TadoDevice_bridge_sets = (
);

my %TadoDevice_thermostat_sets = (
sayHi  => ' '
);



sub Initialize($)
{
	my ($hash) = @_;

	$hash->{ParseFn}    = \&TadoDevice_Parse;
	$hash->{DefFn}      = \&TadoDevice_Define;
	$hash->{UndefFn}    = \&TadoDevice_Undef;
	$hash->{SetFn}      = \&TadoDevice_Set;
	$hash->{GetFn}      = \&TadoDevice_Get;
	$hash->{AttrFn}     = \&TadoDevice_Attr;
	$hash->{ReadFn}     = \&TadoDevice_Read;
	$hash->{AttrList} =
	'earlyStart:true,false '
	. 'subType:zone,bridge,thermostat,weather,mobile_device '
	. 'geoTrackingEnabled:true,false '
	. 'pushNotification_LowBatteryReminder:true,false '
	. 'pushNotification_awayModeReminder:true,false '
	. 'pushNotification_energySavingsReportReminder:true,false '
	. 'pushNotification_homeModeReminder:true,false '
	. 'pushNotification_openWindowReminder:true,false '
	. 'onDemandLogRetrievalEnabled:true,false '
	. 'specialOffersEnabled:true,false '
	. 'pushNotification_energyIqReminder:true,false '
	. 'pushNotification_incidentDetection:true,false '
	. $readingFnAttributes;
	$hash->{Match} = "^Tado;.*" ;

	Log 3, "TadoDevice module initialized.";
}

sub TadoDevice_Define($$)
{
	my ($hash, $def) = @_;
	my @param = split("[ \t]+", $def);
	my $name = $hash->{NAME};

	Log3 $name, 3, "TadoDevice_Define $name: called ";

	my $errmsg = '';

	# Check parameter(s)
	if( int(@param) != 4 ) {
		$errmsg = return "syntax error: define <name> TadoDevice <TadoID> <IODev=IoDevice>";
		Log3 $name, 1, "Tado $name: " . $errmsg;
		return $errmsg;
	}

	#TODO add some validation for SerialNo and ZoneId
	$hash->{TadoId} = $param[2];

	my $iodev;
	my $i = 0;
	foreach my $entry ( @param ) {
		if( $entry =~ m/IODev=([^\s]*)/ ) {
			$iodev = $1;
			last;
		}
		$i++;
	}

  readingsSingleUpdate($hash, 'state', 'Initialized', 0);
	AssignIoPort($hash,$iodev) if( !$hash->{IODev} );

	if(defined($hash->{IODev})) {
		Log3 $name, 3, "Tado $name: I/O device is " . $hash->{IODev}->{NAME};
	} else {
		Log3 $name, 1, "Tado $name: no I/O device";
	}

	my $code = $hash->{IODev}->{NAME} . "-" . InternalVal($name, "TadoId", undef);

	Log3 $name, 3, "Device Code is: " . $code;

	my $d = $modules{TadoDevice}{defptr}{$code};

	return "TadoDevice device $hash->{ID} on Tado $iodev already defined as $d->{NAME}."	if( defined($d)
	&& $d->{IODev} && $hash->{IODev} && $d->{IODev} == $hash->{IODev}
	&& $d->{NAME} ne $name );

	$modules{TadoDevice}{defptr}{$code} = $hash;

	return undef;
}

sub TadoDevice_Undef($$)
{
	my ($hash, $arg) = @_;
	my $name = $hash->{NAME};

	my $code = $hash->{IODev}->{NAME} . "-" . InternalVal($name, "TadoId", undef);
	delete($modules{TadoDevice}{defptr}{$code});

	return undef;
}

sub TadoDevice_Parse ($$)
{
	my ( $io_hash, $message) = @_;
	my $name = $io_hash->{NAME};

	my @values = split(';', $message);

	my $code = $name . "-" . $values[1];
	Log3 $name, 5, "TadoDevice_Parse: Device Code is: " . $code;

	if(my $hash = $modules{TadoDevice}{defptr}{$code})
	{
    $name = $hash->{NAME};
    Log3 $name, 3, "TadoDevice_Parse: Dispatched message arrived in TadoDevice $name";
    Log3 $name, 4, "TadoDevice_Parse: Message was split, message is: " . join(", ", @values);

		if($values[2] eq 'temp'){

		    Processing_Temperature($hash, \@values);

		} elsif ($values[2] eq 'earlyStart') {

			CommandAttr(undef,"$name earlyStart $values[3]");

		} elsif ($values[2] eq 'weather') {

        Processing_Weather($hash, \@values);

		} elsif ($values[2] eq 'locationdata') {

       Processing_LocationData ($hash, \@values);

		} elsif ($values[2] eq 'airComfort') {

       Processing_AirComfort ($hash, \@values);

		} elsif ($values[2] eq 'devicedata') {

       Processing_DeviceData ($hash, \@values);

		}

		# Rückgabe des Gerätenamens, für welches die Nachricht bestimmt ist.
		return $hash->{NAME};
	}
	else
	{
		Log3 "TadoDevice", 2, "TadoDevice: No device entry found for code $code. Tried to process message: $message";
		return "UNDEFINED. Please define TadoDevice for tado ID $values[0]";
	}
}


sub Processing_Temperature {

  my $hash   = shift;
  my $vals   = shift;
  my @values = @{$vals};

  my $name = $hash->{NAME};

  readingsBeginUpdate($hash);

  WriteReading($hash, "measured-temp", $values[3] );
  WriteReading($hash, "measured-temp-timestamp", $values[4]);
  WriteReading($hash, "measured-temp-fahrenheit", $values[5]);
  WriteReading($hash, "measured-temp-precision", $values[6] );
  WriteReading($hash, "measured-temp-precision-fahrenheit", $values[7] ) ;
  WriteReading($hash, "desired-temp", $values[8] );

  WriteReading($hash, "measured-humidity", $values[9] );
  WriteReading($hash, "measured-humidity-timestamp", $values[10] );

  WriteReading($hash, "link", $values[11] );




  WriteBooleanReading($hash, "open-window-plain-reading", $values[12], 1);
  WriteBooleanReading($hash, "open-window-detected-plain-reading", $values[13], 1);
  WriteReading($hash, "open-window", ($values[12] eq 'true' || $values[13] eq 'true') ? 'true' : 'false' );


  WriteReading($hash, "heating-percentage", $values[14] ) ;
  WriteReading($hash, "heating-percentage-timestamp", $values[15] );

  WriteReading($hash, "nextScheduleChange-temperature", $values[16] );
  WriteReading($hash, "nextScheduleChange-power", $values[17] );


  WriteReading($hash, "nextScheduleChange-start", $values[18]);

  WriteReading($hash, "tado-mode", $values[19]);

  WriteReading($hash, "overlay-active", $values[20]);

  if ($values[20] eq "1"){
    WriteReading($hash, "overlay-mode", $values[21]) ;
    WriteReading($hash, "overlay-power", $values[22]);
    WriteReading($hash, "overlay-desired-temperature", $values[23]);
    WriteReading($hash, "overlay-termination-mode", $values[25]);
    WriteReading($hash, "overlay-termination-durationInSeconds", $values[25]);
    WriteReading($hash, "overlay-termination-expiry", $values[26]);
    WriteReading($hash, "overlay-termination-remainingTimeInSeconds", $values[27]);
  } else {
    Log3 $name, 5, "TadoDevice_Parse: No overlay data available. Deleting overlay readings.";
    readingsDelete($hash, "overlay-mode" );
    readingsDelete($hash, "overlay-power");
    readingsDelete($hash, "overlay-desired-temperature");
    readingsDelete($hash, "overlay-termination-mode");
    readingsDelete($hash, "overlay-termination-durationInSeconds");
    readingsDelete($hash, "overlay-termination-expiry");
    readingsDelete($hash, "overlay-termination-remainingTimeInSeconds");
  }

  readingsEndUpdate($hash, 1);


  if ($values[11] eq 'ONLINE'){
    if ($values[8] ne 'OFF') {
      if ($values[9] ne '') {
        readingsSingleUpdate($hash, 'state', sprintf("T: %.1f &deg;C desired: %.1f &deg;C H: %.1f%%", $values[3], $values[8], $values[9]), 1);
      } else {
          if ($values[3] ne '') {
                                      readingsSingleUpdate($hash, 'state', sprintf("T: %.1f &deg;C desired: %.1f &deg;C", $values[3], $values[8]), 1);
          } else {
                                      readingsSingleUpdate($hash, 'state', sprintf("desired: %.1f &deg;C", $values[8]), 1);
          }
      }
    } else {
      if ($values[9] ne '') {
         readingsSingleUpdate($hash, 'state', sprintf("T: %.1f &deg;C desired: off H: %.1f%%", $values[3],  $values[9]), 1);
        } else {
         if ($values[3] ne '') {
         readingsSingleUpdate($hash, 'state', sprintf("T: %.1f &deg;C desired: off", $values[3]), 1);
         } else {
                                             readingsSingleUpdate($hash, 'state', "desired: off", 1);
         }
      }
    }
  } else {
    readingsSingleUpdate($hash, 'state', "Device is in status '$values[11]'.", 1);
  }

}

sub Processing_Weather {

  my $hash   = shift;
  my $vals   = shift;
  my @values = @{$vals};

  my $name = $hash->{NAME};

  readingsBeginUpdate($hash);

  readingsBulkUpdate($hash, "solarIntensity", $values[3] ) if( defined($values[3]) && !($values[3] eq ''));
  readingsBulkUpdate($hash, "solarIntensity-timestamp", $values[4] ) if( defined($values[4]) && !($values[4] eq ''));
  readingsBulkUpdate($hash, "outsideTemperature", $values[5] ) if( defined($values[5]) && !($values[5] eq ''));
  readingsBulkUpdate($hash, "outsideTemperature-timestamp", $values[6] ) if( defined($values[6]) && !($values[6] eq ''));
  readingsBulkUpdate($hash, "weatherState", $values[7] ) if( defined($values[7]) && !($values[7] eq ''));
  readingsBulkUpdate($hash, "weatherState-timestamp", $values[8] ) if( defined($values[8]) && !($values[8] eq ''));

  readingsEndUpdate($hash, 1);

  readingsSingleUpdate($hash, 'state', sprintf("T: %.1f &deg;C Solar: %.1f%% <br>%s", $values[5], $values[3], $values[7]) , 1);

}

sub Processing_LocationData {

  my $hash   = shift;
  my $vals   = shift;
  my @values = @{$vals};

  my $name = $hash->{NAME};

  readingsBeginUpdate($hash);

  WriteBooleanAttribute($name, 'geoTrackingEnabled', $values[3]);
  WriteBooleanAttribute($name, 'specialOffersEnabled', $values[20]);
  WriteBooleanAttribute($name, 'onDemandLogRetrievalEnabled', $values[21]) if( defined($values[21]) && !($values[21] eq ''));

  WriteBooleanReading($hash, 'stale', $values[4]);
  WriteBooleanReading($hash, "atHome", $values[5]);

  WriteReading($hash, "bearingFromHome_degrees", $values[6]);
  WriteReading($hash, "bearingFromHome_radians", $values[7]);
  WriteReading($hash, "relativeDistanceFromHomeFence", $values[8]);

  WriteBooleanAttribute($name, 'pushNotification_LowBatteryReminder', $values[9]);
  WriteBooleanAttribute($name, 'pushNotification_awayModeReminder', $values[10]);
  WriteBooleanAttribute($name, 'pushNotification_homeModeReminder', $values[11]);
  WriteBooleanAttribute($name, 'pushNotification_openWindowReminder', $values[12]);
  WriteBooleanAttribute($name, 'pushNotification_energySavingsReportReminder', $values[13]);
  WriteBooleanAttribute($name, 'pushNotification_incidentDetection', $values[14]);
  WriteBooleanAttribute($name, 'pushNotification_energyIqReminder', $values[15]);

  readingsBulkUpdate($hash, "device_os_version", $values[17] ) if( defined($values[15]) && !($values[17] eq ''));


  if ($values[3] eq '0') {
    readingsBulkUpdate($hash, 'state', sprintf("Tracking: OFF"), 1);
    readingsBulkUpdate($hash, "homeState", "Off");
  } else {
      my $homeState = defined $values[5] ? $values[5] : 'undef';
      $homeState = $homeState ?  "HOME" : "AWAY";
      readingsBulkUpdate($hash, 'state', $homeState , 1);
      readingsBulkUpdate($hash, "homeState", $homeState);
  }


  readingsEndUpdate($hash, 1);
}

sub Processing_AirComfort {

  my $hash   = shift;
  my $vals   = shift;
  my @values = @{$vals};

  my $name = $hash->{NAME};

  readingsBeginUpdate($hash);

  readingsBulkUpdate($hash, "airComfort_temperatureLevel", $values[3] ) if( defined($values[3]) && !($values[3] eq ''));
  readingsBulkUpdate($hash, "airComfort_humidityLevel", $values[4] ) if( defined($values[4]) && !($values[4] eq ''));
  readingsBulkUpdate($hash, "airComfort_graph_radial", $values[5] ) if( defined($values[5]) && !($values[5] eq ''));
  readingsBulkUpdate($hash, "airComfort_graph_angular", $values[6] ) if( defined($values[6]) && !($values[6] eq ''));

  readingsEndUpdate($hash, 1);

}

sub Processing_DeviceData {

  my $hash   = shift;
  my $vals   = shift;
  my @values = @{$vals};

  my $name = $hash->{NAME};

  readingsBeginUpdate($hash);

  readingsBulkUpdate($hash, "currentFwVersion", $values[3] ) if( defined($values[3]) && !($values[3] eq ''));
  readingsBulkUpdate($hash, "inPairingMode", $values[4] ) if( defined($values[4]) && !($values[4] eq ''));
  readingsBulkUpdate($hash, "batteryState", $values[5] ) if( defined($values[5]) && !($values[5] eq ''));
  readingsBulkUpdate($hash, "connectionState", $values[6] ) if( defined($values[6]) && !($values[6] eq ''));
  readingsBulkUpdate($hash, "connectionStateLastUpdate", $values[7] ) if( defined($values[7]) && !($values[7] eq ''));

  readingsEndUpdate($hash, 1);

}



sub WriteBooleanAttribute {

  my $name = shift;
	my $attributeName = shift;
	my $attributeValue = shift;

	if( defined($attributeValue) && !($attributeValue eq '')) {
		my $value = (int($attributeValue) < 1) ? 'false' : 'true';
		my $currentValue = AttrVal($name, $attributeName, 'N/A');
		Log3 $name, 5, "Attribute $attributeName: comparing old value $currentValue with new value $value.";
		if ($currentValue ne $value) {
			Log3 $name, 3, "Writing attribute $attributeName for device $name to $value.";
			CommandAttr(undef,"$name $attributeName $value");
		}
	}
}

sub WriteBooleanReading {
	my $hash = shift;
	my $readingName = shift;
	my $readingValue = shift;
  my $deleteIfNotSet = shift;

	if( defined($readingValue) && !($readingValue eq '')) {
		my $value = (int($readingValue) < 1) ? 'false' : 'true';
		WriteReading($hash, $readingName, $value);
	} elsif ($deleteIfNotSet) {
    WriteReading($hash, $readingName, 'false');
	} else {
    readingsDelete($hash, $readingName);
  }
}

sub WriteReading {
	my $hash = shift;
	my $readingName = shift;
	my $readingValue = shift;
	my $name = $hash->{NAME};

	if( defined($readingValue) && !($readingValue eq '')) {
		readingsBulkUpdate($hash, $readingName, $readingValue );
	} else {
		readingsDelete($hash, $readingName);
	}
}


sub Processing_MessageTemperature {
    my $hash         = shift;
    my $decoded_json = shift;

    my $name = $hash->{NAME};
    readingsBeginUpdate($hash);
    readingsBulkUpdate( $hash, 'session_energy', 'N/A' );
    readingsBulkUpdate( $hash, 'session_start', 'N/A' );
    readingsBulkUpdate( $hash, 'session_end', 'N/A' );
    readingsBulkUpdate( $hash, 'session_chargeDurationInSeconds', 'N/A' );
    readingsBulkUpdate( $hash, 'session_firstEnergyTransfer', 'N/A' );
    readingsBulkUpdate( $hash, 'session_lastEnergyTransfer', 'N/A' );
    readingsBulkUpdate( $hash, 'session_pricePerKWH', 'N/A' );
    readingsBulkUpdate( $hash, 'session_chargingCost', 'N/A' );
    readingsBulkUpdate( $hash, 'session_id', 'N/A' );
    readingsEndUpdate( $hash, 1 );
    return;
}



sub TadoDevice_Get($@)
{

	my ($hash, $name, @param) = @_;

	return '"set $name" needs at least one argument' if (int(@param) < 1);

	my $opt = shift @param;

	if(!defined($TadoDevice_gets{$opt})) {
		my @cList = keys %TadoDevice_gets;
		return "Unknown argument $opt, choose one of " . join(" ", @cList);
	}

	if ($opt eq "update")	{
		IOWrite($hash, "Update", InternalVal($name, "TadoId", undef));
	}

	return undef;
}


sub TadoDevice_Set($@)
{
	my ($hash, $name, @param) = @_;

	return "set $name needs at least one argument" if (int(@param) < 1);

	my $opt = shift @param;
	my $value = join("", @param);

	if (AttrVal($name, 'subType', 'nix') eq 'zone') {
		if(!defined($TadoDevice_zone_sets{$opt})) {
			#my @cList = keys %TadoDevice_zone_sets;
			my $validValues = TadoDevice_GenerateTemperatureSchema();
			return "Unknown argument $opt, choose one of " . $validValues; #join(" ", @cList);
		}
	} elsif (AttrVal($name, 'subType', 'nix') eq 'bridge') {

		if(!defined($TadoDevice_bridge_sets{$opt})) {
			my @cList = keys %TadoDevice_bridge_sets;
			return "Unknown argument $opt, choose one of " . join(" ", @cList);
    }

	} elsif (AttrVal($name, 'subType', 'nix') eq 'heating') {

  		if(!defined($TadoDevice_zone_sets{$opt})) {
  			my @cList = keys %TadoDevice_zone_sets;
  			return "Unknown argument $opt, choose one of " . join(" ", @cList);
      }

	} else  {

		if(!defined($TadoDevice_thermostat_sets{$opt})) {
			my @cList = keys %TadoDevice_thermostat_sets;
			return "Unknown argument $opt, choose one of " . join(" ", @cList);

		}
	}

	if ($opt eq "automatic")	{
		IOWrite($hash, "Temp", InternalVal($name, "TadoId", undef) , "Auto");
	} elsif ($opt eq "off")	{
		IOWrite($hash, "Temp", InternalVal($name, "TadoId", undef), "0" , "off");
	} elsif ($opt eq "sayHi")	{
		IOWrite($hash, "Hi", InternalVal($name, "TadoId", undef));
	} else {

		my $temperature = shift @param;


		if (not defined $temperature) {return "Missing temperature value. Please insert numeric value or lower case string 'off'"}
		if (not (looks_like_number($temperature) || $temperature eq 'off' )) {return "Invalid temperature value. Please insert numeric value or lower case string 'off'"}

		if ($opt eq "temperature")	{
			IOWrite($hash, "Temp", InternalVal($name, "TadoId", undef), "0" , $temperature);
		} elsif ($opt eq "temperature-for-60")	{
			IOWrite($hash, "Temp", InternalVal($name, "TadoId", undef), "60" , $temperature);
		} elsif ($opt eq "temperature-for-90")	{
			IOWrite($hash, "Temp", InternalVal($name, "TadoId", undef), "90" , $temperature);
		} elsif ($opt eq "temperature-for-120")	{
			IOWrite($hash, "Temp", InternalVal($name, "TadoId", undef), "120" , $temperature);
		} elsif ($opt eq "temperature-for-180")	{
			IOWrite($hash, "Temp", InternalVal($name, "TadoId", undef), "180" , $temperature);
		} elsif ($opt eq "temperature-for-240")	{
			IOWrite($hash, "Temp", InternalVal($name, "TadoId", undef), "240" , $temperature);
		} elsif ($opt eq "temperature-for-300")	{
			IOWrite($hash, "Temp", InternalVal($name, "TadoId", undef), "300" , $temperature);
		}
	}
}

sub TadoDevice_Attr(@)
{
	my ($cmd,$name,$aName,$aVal) = @_;
	my $hash = $defs{$name};

	if (defined $aVal){
			Log3 $aName, 5, "TadoDevice: $name AttributeChange. CMD: $cmd, name: $aName, value: $aVal.";
	} else {
    	Log3 $aName, 5, "TadoDevice: $name AttributeChange. CMD: $cmd, name: $aName";
  }

	if ($aName eq "earlyStart") {
		if ($cmd eq "set") {
			if ($aVal ne 'true' && $aVal ne 'false') {
				return "Invalid attribute value. Attribute earlyStart only supports values 'true' and 'false'";
			}
			Log3 $hash, 3, "TadoDevice: $name EarlyStart $aVal.";

			my $ret = IOWrite($hash, "EarlyStart", InternalVal($name, "TadoId", undef), $aVal);

			if ($ret eq "0" or $ret eq "1"){
				$hash->{EARLY_START} = $aVal;
				return undef;
			} else {
				return $ret;
			}
		} elsif ($cmd eq "del"){
			Log3 $hash, 3, "TadoDevice: $name EarlyStart attribute was deleted. Setting earlyStart to false via Tado web API.";
			my $ret = IOWrite($hash, "EarlyStart", InternalVal($name, "TadoId", undef), 'false');
			if ($ret eq "0" or $ret eq "1"){
				$hash->{EARLY_START} = 'false';
				return undef;
			} else {
				return $ret;
			}
		}
	}

	if ($aName eq "geoTrackingEnabled") {
		if ($cmd eq "set") {
			if ($aVal ne 'true' && $aVal ne 'false') {
				return "Invalid attribute value. Attribute geoTrackingEnabled only supports values 'true' and 'false'";
			}
			Log3 $hash, 3, "TadoDevice: $name geoTrackingEnabled $aVal.";
			my $ret = IOWrite($hash, "geoTrackingEnabled", InternalVal($name, "TadoId", undef), $aVal);
			return $ret;
		} elsif ($cmd eq "del"){
			Log3 $hash, 3, "TadoDevice: $name geoTrackingEnabled attribute was deleted. Setting geoTrackingEnabled to false via Tado web API.";
			my $ret = IOWrite($hash, "geoTrackingEnabled", InternalVal($name, "TadoId", undef), 'false');
			return $ret;
		}
	}

		if ($aName =~ 'geoTrackingEnabled|onDemandLogRetrievalEnabled|specialOffersEnabled') {
		if ($cmd eq "set") {
			if ($aVal ne 'true' && $aVal ne 'false') {
				return "Invalid attribute value. Attribute $aName only supports values 'true' and 'false'";
			}
			Log3 $hash, 3, "TadoDevice: $name $aName $aVal.";
			my $ret = IOWrite($hash, $aName, InternalVal($name, "TadoId", undef), $aVal);
			return $ret;
		} elsif ($cmd eq "del"){
			Log3 $hash, 3, "TadoDevice: $name $aName attribute was deleted. Setting geoTrackingEnabled to false via Tado web API.";
			my $ret = IOWrite($hash, $aName, InternalVal($name, "TadoId", undef), 'false');
			return $ret;
		}
	}


	if ($aName =~ /^pushNotification/) {
		if ($cmd eq "set") {
			if ($aVal ne 'true' && $aVal ne 'false') {
				return "Invalid attribute value. Attribute $aName only supports values 'true' and 'false'";
			}
			Log3 $hash, 3, "TadoDevice: $name $aName $aVal.";
			my $p1 = ($aName eq 'pushNotification_LowBatteryReminder') ? $aVal : AttrVal($name,"pushNotification_LowBatteryReminder","false");
			my $p2 = ($aName eq 'pushNotification_awayModeReminder') ? $aVal : AttrVal($name,"pushNotification_awayModeReminder","false");
			my $p3 = ($aName eq 'pushNotification_homeModeReminder') ? $aVal : AttrVal($name,"pushNotification_homeModeReminder","false");
			my $p4 = ($aName eq 'pushNotification_energySavingsReportReminder') ? $aVal : AttrVal($name,"pushNotification_energySavingsReportReminder","false");
			my $p5 = ($aName eq 'pushNotification_openWindowReminder') ? $aVal : AttrVal($name,"pushNotification_openWindowReminder","false");

			my $p6 = ($aName eq 'pushNotification_incidentDetection') ? $aVal : AttrVal($name,"pushNotification_incidentDetection","");
			my $p7 = ($aName eq 'pushNotification_energyIqReminder') ? $aVal : AttrVal($name,"pushNotification_energyIqReminder","");
			my $ret = IOWrite($hash, "pushNotifications", InternalVal($name, "TadoId", undef), $p1, $p2, $p3, $p4, $p5, $p6, $p7);
			return $ret;
		} elsif ($cmd eq "del"){
			Log3 $hash, 3, "TadoDevice: $name geoTrackingEnabled attribute was deleted. Setting geoTrackingEnabled to false via Tado web API.";
			my $ret = IOWrite($hash, "geoTrackingEnabled", InternalVal($name, "TadoId", undef), 'false');
			return $ret;
		}
	}


	return undef;
}

sub TadoDevice_GenerateTemperatureSchema()
{
	my $valueString = "off";
  for (my $i=5;$i<=25;$i+=0.5){
	  $valueString .= ",$i"
  }

 my $response = "";
 foreach my $item (keys %TadoDevice_zone_sets){
   if ($item =~ /^temperature/) {$response .= $item.":".$valueString." ";}
   else {$response .= $item." ";}
  }

return $response;
}


1;

=pod
=begin html

<a name="TadoDevice"></a>
<h3>TadoDevice</h3>
<ul>
    <i>TadoDevice</i> is the implementation of a zone, a device, a mobile device or the weather channel connected to one Tado instance and therefor one tado cloud account. It can only be used in conjunction with a Tado instance (a Tado bridge). The TadoDevice is intended to display the current measurements of a zone or device and allow the interaction. It can be used to set or reset the temperature within a zone or to display a "hi" statement on a physical Tado device. It can also be used to identify which mobile devices are at home. TadoDevices should not be created manually. They are auto generated once a Tado device is defined.
    <br>
    <br>
    <a name="TadoDevicedefine"></a>
    <b>Define</b>
    <ul>
        <code>define &lt;name&gt; TadoDevice &lt;TadoId&gt; &lt;IODev=IODeviceId&gt;</code>
        <br>
        <br> Example: <code>define kitchen TadoDevice 1 IODev=TadoBridge</code>
        <br>
        <br> Normally the define statement should be called by the Tado device. If called manually the TadoId and the IO-Device must be provided. The TadoId is either the zone Id if a zone shall be created or the serial number of a physical device. The IO-Device must be of type Tado.
    </ul>
    <br>
    <a name="TadoDeviceset"></a>
    <b>Set</b>
    <br>
    <ul>
        <code>set &lt;name&gt; &lt;option&gt; &lt;value&gt;</code>
        <br>
        <br> What can be done with the <i>set</i> command is depending on the subtype of the TadoDevice. For all thermostats it is possible to set the temperature using the automatic, temperature and temperature-for options. For all physical devices the sayHi option is available.
        <br>
        <br> Options:
        <ul>
            <li><i>sayHi</i>
                <br>
                <b>Works on devices only.</b> Sends a request to the a specific physical device. Once the request reaches the device the device displays "HI". Command can be used to identify a physical device.
            </li>
            <li><i>automatic</i>
                <br>
                <b>Works on zones only.</b> Resets all temperature settings for a zone. The plan defined in the cloud (either by app or browser) will be used to set the temperature</li>
            <li><i>off</i>
                <br>
                <b>Works on zones only.</b> Turns the heating in the specific zone completely off. The setting will be kept until a new temperature is defined via app, browser or FHEM.
                <li><i>temperature</i>
                    <br>
                    <b>Works on zones only.</b> Sets the temperature for a zone. The setting will be kept until a new temperature is defined via app, browser or FHEM. Value can be <i>off</i> or any numeric value between 4.0 and 25.0 with a precision of 0.1 degree.
                    <li><i>temperature-for-60</i>
                        <br>
                        <b>Works on zones only.</b> Sets the temperature for a zone for 60 minutes only. The temperature will be kept for 60 minutes. Afterwards the zone will fall back to the standard plan defined in app or web. Value definition is like for command <i>set temperature</i>.</li>
                    <li><i>temperature-for-90</i>
                        <br>
                        <b>Works on zones only.</b> Sets the temperature for a zone for 90 minutes only. The temperature will be kept for 90 minutes. Afterwards the zone will fall back to the standard plan defined in app or web. Value definition is like for command <i>set temperature</i>.</li>
                    <li><i>temperature-for-120</i>
                        <br>
                        <b>Works on zones only.</b> Sets the temperature for a zone for 120 minutes only. The temperature will be kept for 120 minutes. Afterwards the zone will fall back to the standard plan defined in app or web. Value definition is like for command <i>set temperature</i>.</li>
                    <li><i>temperature-for-180</i>
                        <br>
                        <b>Works on zones only.</b> Sets the temperature for a zone for 180 minutes only. The temperature will be kept for 180 minutes. Afterwards the zone will fall back to the standard plan defined in app or web. Value definition is like for command <i>set temperature</i>.</li>
                    <li><i>temperature-for-240</i>
                        <br>
                        <b>Works on zones only.</b> Sets the temperature for a zone for 240 minutes only. The temperature will be kept for 240 minutes. Afterwards the zone will fall back to the standard plan defined in app or web. Value definition is like for command <i>set temperature</i>.</li>
                    <li><i>temperature-for-300</i>
                        <br>
                        <b>Works on zones only.</b> Sets the temperature for a zone for 300 minutes only. The temperature will be kept for 300 minutes. Afterwards the zone will fall back to the standard plan defined in app or web. Value definition is like for command <i>set temperature</i>.</li>
        </ul>
    </ul>
    <br>
    <a name="TadoDeviceget"></a>
    <b>Get</b>
    <br>
    <ul>
        <code>get &lt;name&gt; &lt;option&gt;</code>
        <br>
        <br> The only available <i>get</i> function is called <b>update</b> and can be used to update all readings of the specific TadoDevice.
        <br>
        <br> Options:
        <ul>
            <li><i>Update</i>
                <br>
                <b>This <i>get</i> command is available on zones, weather and mobile devices</b> This call updates the readings of a <i>TadoDevie</i> with the latest values available in the Tado cloud.
            </li>
        </ul>
    </ul>
    <br>
    <a name="TadoDeviceattr"></a>
    <b>Attributes</b>
    <ul>
        <code>attr &lt;name&gt; &lt;attribute&gt; &lt;value&gt;</code>
        <br>
        <br> There is one attribute available. It only affects zones.
        <br>
        <br> Attributes:
        <ul>
            <li><i>earlyStart</i> true|false
                <br> When set to true the Tado system starts to heat up before the set heating change. The intention is to reach the target temperature right at the point in time defined. E.g. if you want to change the temperature from 20 degree to 22 degree on 6pm early start would start heating at 5:30pm so the zone is on 22 degree at 6pm. The early start is a feature of Tado. How this is calculated and how early the heating is started is up to Tado.
            </li>
        </ul>
    </ul>
    <br>
    <br>
    <a name="TadoDevicereadings"></a>
    <b>Generated Readings/Events for subtype <i>zone</i>:</b>
    <br>
    <br>
    <ul>
        <li><b>Basic readings</b>
            <br> Contains a list of the basic readings beeing available all the time. This is mainly the status of the room, the actual measured values and the desired values.</li>
        <br>
        <ul>
            <li><b>date_created</b>
                <br> Indicates when this zone was created within the Tado account (not within FHEM).
            </li>
            <li><b>link</b>
                <br> Indicates if the Tado hardware in the specific zone is currently ONLINE or OFFLINE.
            </li>
            <li><b>tado-mode</b>
                <br> Indicates if the heating parameters applied to the specific zone are based on the <i>HOME</> or the <i>AWAY</i> configuration.
            </li>
            <li><b>desired-temp</b>
                <br> The desired room or water temperature.
            </li>
            <li><b>measured-temp</b>
                <br> The temperature measured by the Tado device in the specific zone / room in °C
            </li>
            <li><b>measured-temp-fahrenheit</b>
                <br> The temperature measured by the Tado device in the specific zone / room in °F
            </li>
            <li><b>measured-temp-precision</b>
                <br> Indicates the precision of the data beeing provided in <i>measured-temp</i> reading.
            </li>
            <li><b>measured-temp-precision-fahrenheit</b>
                <br> Indicates the precision of the data beeing provided in <i>measured-temp-fahrenheit</i> reading.
            </li>
            <li><b>measured-temp-timestamp</b>
                <br> Indicates when the values in <i>measured-temp</i> and <i>measured-temp-fahrenheit</i> were actually measured.
                <br> If the connection between the Tado bridge and the Tado webserver is broken values may get aged. This can be identified using this reading.
            </li>
            <li><b>measured-humidity</b>
                <br> The humidity measured by the Tado device in the specific zone / room in %
            </li>
            <li><b>measured-humidity-timestamp</b>
                <br> Indicates when the value in <i>measured-humidity</i> was actually measured.
                <br> If the connection between the Tado bridge and the Tado webserver is broken values may get aged. This can be identified using this reading.
            </li>
            <li><b>heating-percentage</b>
                <br> If your heating is capable to run in a more fine grained operation mode than purly ON and OFF and Tado is capable to control the heating on this level, the current heating level in percent is contained in this reading.
                <br> Example: If you do have a floor heating the heating temperature is controlled by a valve which can be opened in 10% steps. In this case this reading contains valid values.
            </li>
            <li><b>heating-percentage-timestamp</b>
                <br> Indicates when the value in <i>heating-percentage</i> was actually measured.
                <br> If the connection between the Tado bridge and the Tado webserver is broken values may get aged. This can be identified using this reading.
            </li>
            <li><b>open-window</b>
                <br> If tado recognizes an open window within the current zone / room this reading contains the timestamp since when the window is open. If no open window is detected the reading contains the value <i>null</i>
            </li>
            <li><b>supportsDazzle</b>
                <br> Tado dazzle mode shows status changes made via web or mobile app on the Tado device. E.g. if you change the temperature in a zone / room via app, the Tado device displays the new temperature for some seconds so you can check you chnaged the correct device. This reading indicates if the current zone / room and the devices within support dazzle mode.
            </li>
        </ul>
        <br>
        <li><b>Scheduled Changes</b>
            <br> Tado supports so called <i>intelligent schedules</i>. Within an intelligent schedule certain timeframes are defined and within the timeframes the desired temperature is set. As the intelligent part of the feature Tado documents previous heating cycles and knows the time it takes to heat up. So Tado starts heating before the scheduled date so the room is already at desired temperature when the schedule changes. A zone / room can have different intelligent schedules depending on the <i>tado-mode</i> HOME and AWAY.
        </li>
        <br>
        <ul>
            <li><b>nextScheduleChange-start</b>
                <br> This reading indicates when the next interval of the schedule will begin.
            </li>
            <li><b>nextScheduleChange-power</b>
                <br> This reading indicates weather the zone will be powered or not on the next change. This could be a heating turned on or a warm water boiler turned to heating mode.
            </li>
            <li><b>nextScheduleChange-temperature</b>
                <br> This reading indicates the desired temperature for the next scheduled change.
            </li>
        </ul>
        <br>
        <li><b>Overlay - Manual temperature adjustments</b>
            <br> If you manually adjust the temperature for a zone / room either using the Tado device or the Tado app this is calles an override. An override can be temporary and will end after a certain time periode or it is infinite and stays active until it is ended by the user.
        </li>
        <br>
        <ul>
            <li><b>overlay-active</b>
                <br> This reading indicates if such an override is active (<i>1</i>) or inactive (<i>0</i>).
            </li>
            <li><b>overlay-desired-temperature</b>
                <br> This reading indicates the desired temperature while the overlay is active.
            </li>
            <li><b>overlay-mode</b>
                <br> This reading indicates the mode of the overlay.
            </li>
            <li><b>overlay-power</b>
                <br> This reading indicates if the heating, boiler or AC is turned on while the overlay is active.
            </li>
            <li><b>overlay-termination-mode</b>
                <br> This reading indicates the termination mode currently active.
                <i>MANUAL</i> indicates the current mode will be active until it is changed by the user and <i>TIMER</i> means it automatically gets disabled once the timer is expired.
            </li>
            <li><b>overlay-termination-durationInSeconds</b>
                <br> This reading indicates how long the overlay will be active in seconds.
            </li>
            <li><b>overlay-termination-expiry</b>
                <br> This reading indicates the date and time when the overlay will expire and Tado will return to automatic operation.
            </li>
            <li><b>overlay-termination-remainingTimeInSeconds</b>
                <br> This reading indicates the remaining time in seconds until the zone / room will be turned back to automatic operation.
            </li>
        </ul>
        <br>
        <li><b>Overlay - Manual temperature adjustments</b>
            <br> The measured humidity and temperature in a room are evaluated and an air comfort is calculated. The air comfort is provided in english, human readable words for humidity and temperature and by a radar chart visualizing the air comfort. The graph is displayed in the Tado app but cannnot be displayed in FHEM. But you can use the angular and radial values to create your own radar chart.
        </li>
        <br>
        <ul>
            <li><b>airComfort_humidityLevel</b>
                <br> An english, human readable expression defining the air comfort of your current humidity level.
            </li>
            <li><b>airComfort_temperatureLevel</b>
                <br> An english, human readable expression defining the air comfort of your current temperature level.
            </li>
            <li><b>airComfort_graph_angular</b>
                <br> A radar chart has an angular and a radial axis. This reading contains the numeric value for the angular axis.
            </li>
            <li><b>airComfort_graph_radial</b>
                <br> A radar chart has an angular and a radial axis. This reading contains the numeric value for the radial axis.
            </li>
        </ul>
    </ul>
    <br>
    <br>
    <b>Generated Readings/Events for subtype <i>thermostat</i> and <i>bridge</i>:</b>
    <br>
    <br>
    <ul>
        <ul>
            <li><b>batteryState</b>
                <br> The state of the battery for the Tado hardware device.
            </li>
            <li><b>connectionState</b>
                <br> The current connection state.
            </li>
            <li><b>connectionStateLastUpdate</b>
                <br> Date and time when the current connection state was registered in the Tado cloud application.
            </li>
            <li><b>currentFwVersion</b>
                <br> The firmware version of the Tado hardware.
            </li>
            <li><b>inPairingMode</b>
                <br> Indicates if a Tado bridge device is in pairing mode and accepts new Tado devices.
            </li>
        </ul>
    </ul>
    <br>
    <br>
    <b>Generated Readings/Events for subtype <i>mobile_device</i>:</b>
    <br>
    <br>
    <ul>
        <ul>
            <li><b>device_locale</b>
                <br> The languange settings for the device.
            </li>
            <li><b>device_model</b>
                <br> The model or make of the device.
            </li>
            <li><b>device_os_version</b>
                <br> The operating system version of the device.
            </li>
            <li><b>device_platform</b>
                <br> The software platform of the device.
            </li>
            <li><b>geoTrackingEnabled</b>
                <br> Indicates if geofencing is enabled for the device. If geofencing is enabled Tado can switch between the presence modes of HOME and AWAY. To automatically switch you do need a paid premium plan. Otherwise you get a push notification on your mobile and can invoke a status change.
            </li>
            <li><b>pushNotification_LowBatteryReminder</b>
                <br> Indicates if the device will get a push notification if the battery of a Tado device is running low.
            </li>
            <li><b>pushNotification_awayModeReminder</b>
                <br> Indicates if the device will get a push notification if the geofencing detects leaving a fenced area and offers to swicth to AWAY mode.
            </li>
            <li><b>pushNotification_homeModeReminder</b>
                <br> Indicates if the device will get a push notification if the geofencing detects entering a fenced area and offers to swicth to HOME mode.
            </li>
            <li><b>pushNotification_energySavingsReportReminder</b>
                <br> Indicates if the device will get a push notification once a new energy saving report is available in Tado Cloud.
            </li>
            <li><b>pushNotification_openWindowReminder</b>
                <br> Indicates if the device will get a push notification if an open window was detected and offers to temporary turn of the heating.
            </li>
        </ul>
    </ul>
    <br>
    <br>
    <b>Generated Readings/Events for subtype <i>weather</i>:</b>
    <br>
    <br>
    <ul>
        <li>The Tado weather is not measured using your local devices. Tado is using weather data from a service provider and the address you configured when creating your Tado account to estimate your local weather. There may be internet data of local weather stations or your own weather station providing much more accurate data.
        </li>
        <ul>
            <li><b>outsideTemperature</b>
                <br> The current outside temperature.
            </li>
            <li><b>outsideTemperature-timestamp</b>
                <br> The timestamp when current outside temperature was updated.
            </li>
            <li><b>solarIntensity</b>
                <br> The current solar intensity - the relative brightness of the sub in %
            </li>
            <li><b>solarIntensity-timestamp</b>
                <br> The timestamp when current solar intensity was updated.
            </li>
            <li><b>weatherState</b>
                <br> An english, human readable text describing the current weather conditions.
            </li>
            <li><b>weatherState-timestamp</b>
                <br> The timestamp when current weather state was updated.
            </li>
        </ul>
    </ul>
</ul>


=end html

=cut
