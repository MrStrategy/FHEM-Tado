package main;
use strict;
use warnings;
use Scalar::Util qw(looks_like_number);

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



sub TadoDevice_Initialize($)
{
	my ($hash) = @_;

	$hash->{ParseFn}    = 'TadoDevice_Parse';
	$hash->{DefFn}      = 'TadoDevice_Define';
	$hash->{UndefFn}    = 'TadoDevice_Undef';
	$hash->{SetFn}      = 'TadoDevice_Set';
	$hash->{GetFn}      = 'TadoDevice_Get';
	$hash->{AttrFn}     = 'TadoDevice_Attr';
	$hash->{ReadFn}     = 'TadoDevice_Read';
	$hash->{AttrList} =
	'earlyStart:true,false '
	. 'subType:zone,bridge,thermostat,weather,mobile_device '
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

	Log3 'TadoDevice', 5, "TadoDevice_Parse: Dispatched message arrived in TadoDevice Device";


	my @values = split(';', $message);
	Log3 'TadoDevice', 5, "TadoDevice_Parse: Message was split, message is: " . join(", ", @values);

	my $code = $io_hash->{NAME} . "-" . $values[1];
	Log3 'TadoDevice', 5, "TadoDevice_Parse: Device Code is: " . $code;

	if(my $hash = $modules{TadoDevice}{defptr}{$code})
	{
		my $name = $hash->{NAME};
		Log3 $name, 3, "TadoDevice_Parse: Entry found ($code), updating readings";

		if($values[2] eq 'temp'){

			readingsBeginUpdate($hash);

			readingsBulkUpdate($hash, "measured-temp", $values[3] );
			readingsBulkUpdate($hash, "measured-temp-timestamp", $values[4] );
			readingsBulkUpdate($hash, "measured-temp-fahrenheit", $values[5] );
			readingsBulkUpdate($hash, "measured-temp-precision", $values[6] );
			readingsBulkUpdate($hash, "measured-temp-precision-fahrenheit", $values[7] );
			readingsBulkUpdate($hash, "desired-temp", $values[8] );

			readingsBulkUpdate($hash, "measured-humidity", $values[9] );
			readingsBulkUpdate($hash, "measured-humidity-timestamp", $values[10] );

			readingsBulkUpdate($hash, "link", $values[11] );
			readingsBulkUpdate($hash, "open-window", $values[12] );

			readingsBulkUpdate($hash, "heating-percentage", $values[13] );
			readingsBulkUpdate($hash, "heating-percentage-timestamp", $values[14] );

			readingsBulkUpdate($hash, "nextScheduleChange-temperature", $values[15] );
			readingsBulkUpdate($hash, "nextScheduleChange-power", $values[16] );


			readingsBulkUpdate($hash, "nextScheduleChange-start", $values[17]);

			readingsBulkUpdate($hash, "overlay-active", $values[18]);

			if ($values[18] eq "1"){
				readingsBulkUpdate($hash, "overlay-mode", $values[19]);
				readingsBulkUpdate($hash, "overlay-power", $values[20]);
				readingsBulkUpdate($hash, "overlay-desired-temperature", $values[21]);
				readingsBulkUpdate($hash, "overlay-termination-mode", $values[22]);
				readingsBulkUpdate($hash, "overlay-termination-durationInSeconds", $values[23]);
				readingsBulkUpdate($hash, "overlay-termination-expiry", $values[24]);
				readingsBulkUpdate($hash, "overlay-termination-remainingTimeInSeconds", $values[25]);
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
					readingsSingleUpdate($hash, 'state', sprintf("T: %.1f &deg;C desired: %.1f &deg;C H: %.1f%%", $values[3], $values[8], $values[9]), 1);
				} else {
					readingsSingleUpdate($hash, 'state', sprintf("T: %.1f &deg;C desired: off H: %.1f%%", $values[3],  $values[9]), 1);
				}
			} else {
				readingsSingleUpdate($hash, 'state', "Device is in status '$values[11]'.", 1);
			}

		} elsif ($values[2] eq 'earlyStart') {
			CommandAttr(undef,"$name earlyStart $values[3]");
		} elsif ($values[2] eq 'weather') {
			readingsBeginUpdate($hash);

			readingsBulkUpdate($hash, "solarIntensity", $values[3] );
			readingsBulkUpdate($hash, "solarIntensity-timestamp", $values[4] );
			readingsBulkUpdate($hash, "outsideTemperature", $values[5] );
			readingsBulkUpdate($hash, "outsideTemperature-timestamp", $values[6] );
			readingsBulkUpdate($hash, "weatherState", $values[7] );
			readingsBulkUpdate($hash, "weatherState-timestamp", $values[8] );

			readingsEndUpdate($hash, 1);

			readingsSingleUpdate($hash, 'state', sprintf("T: %.1f &deg;C Solar: %.1f%% <br>%s", $values[5], $values[3], $values[7]) , 1);
		} elsif ($values[2] eq 'locationdata') {
			readingsBeginUpdate($hash);

			readingsBulkUpdate($hash, "geoTrackingEnabled", $values[3] );
			readingsBulkUpdate($hash, "location_stale", $values[4] );
			readingsBulkUpdate($hash, "location_atHome", $values[5] );
			readingsBulkUpdate($hash, "bearingFromHome_degrees", $values[6] );
			readingsBulkUpdate($hash, "bearingFromHome_radians", $values[7] );
			readingsBulkUpdate($hash, "location_relativeDistanceFromHomeFence", $values[8] );

			readingsBulkUpdate($hash, "pushNotification_LowBatteryReminder", $values[9] );
			readingsBulkUpdate($hash, "pushNotification_awayModeReminder", $values[10] );
			readingsBulkUpdate($hash, "pushNotification_homeModeReminder", $values[11] );
			readingsBulkUpdate($hash, "pushNotification_openWindowReminder", $values[12] );
			readingsBulkUpdate($hash, "pushNotification_energySavingsReportReminder", $values[13] );

      readingsBulkUpdate($hash, 'state', sprintf("Tracking: %s Home: %s", $values[3], $values[5]), 1);

			readingsEndUpdate($hash, 1);

		} elsif ($values[2] eq 'airComfort') {
			readingsBeginUpdate($hash);

			readingsBulkUpdate($hash, "airComfort_temperatureLevel", $values[3] );
			readingsBulkUpdate($hash, "airComfort_humidityLevel", $values[4] );
			readingsBulkUpdate($hash, "airComfort_graph_radial", $values[5] );
			readingsBulkUpdate($hash, "airComfort_graph_angular", $values[6] );

			readingsEndUpdate($hash, 1);

		}

		# Rückgabe des Gerätenamens, für welches die Nachricht bestimmt ist.
		return $hash->{NAME};
	}
	else
	{
		Log3 'TadoDevice', 2, "No device entry found";
		return "UNDEFINED. Please define TadoDevice for tado ID $values[0]";
	}
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
			Log3 $hash, 5, "TadoDevice: $name AttributeChange. CMD: $cmd, name: $aName, value: $aVal.";
	} else {
    	Log3 $hash, 5, "TadoDevice: $name AttributeChange. CMD: $cmd, name: $aName";
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
    <i>TadoDevice</i> is the implementation of a zone, a device, a mobile device or the weather channel connected to one Tado instance and therefor one tado cloud account.
    It can only be used in conjunction with a Tado instance (a Tado bridge).
    The TadoDevice is intended to display the current measurements of a zone or device and allow
    the interaction. It can be used to set or reset the temperature within a zone or to
    display a "hi" statement on a physical Tado device. It can also be used to identify which mobile devices are at home.
    TadoDevices should not be created manually. They are auto generated once a Tado device is defined.
    <br><br>
    <a name="TadoDevicedefine"></a>
    <b>Define</b>
    <ul>
        <code>define &lt;name&gt; TadoDevice &lt;TadoId&gt; &lt;IODev=IODeviceId&gt;</code>
        <br><br>
        Example: <code>define kitchen TadoDevice 1 IODev=TadoBridge</code>
        <br><br>
        Normally the define statement should be called by the Tado device.
        If called manually the TadoId and the IO-Device must be provided.
        The TadoId is either the zone Id if a zone shall be created or the serial number
        of a physical device. The IO-Device must be of type Tado.
    </ul>
    <br>
    <a name="TadoDeviceset"></a>
    <b>Set</b><br>
    <ul>
        <code>set &lt;name&gt; &lt;option&gt; &lt;value&gt;</code>
        <br><br>
        What can be done with the <i>set</i> command is depending on the subtype
        of the TadoDevice. For all thermostats it is possible to set the temperature using the
        automatic, temperature and temperature-for options. For all physical devices the
        sayHi option is available.
        <br><br>
        Options:
        <ul>
              <li><i>sayHi</i><br>
                  <b>Works on devices only.</b>
                  Sends a request to the a specific physical device. Once the request
                  reaches the device the device displays "HI".
                  Command can be used to identify a physical device.
                  </li>
              <li><i>automatic</i><br>
                  <b>Works on zones only.</b>
                  Resets all temperature settings for a zone.
                  The plan defined in the cloud (either by app or browser) will be used to set the temperature</li>
              <li><i>off</i><br>
                  <b>Works on zones only.</b>
                  Turns the heating in the specific zone completely off.
                  The setting will be kept until a new temperature is defined via app, browser or FHEM.
              <li><i>temperature</i><br>
                  <b>Works on zones only.</b>
                  Sets the temperature for a zone.
                  The setting will be kept until a new temperature is defined via app, browser or FHEM.
                  Value can be <i>off</i> or any numeric value between 4.0 and 25.0 with a precision of 0.1 degree.
              <li><i>temperature-for-60</i><br>
                  <b>Works on zones only.</b>
                  Sets the temperature for a zone for 60 minutes only.
                  The temperature will be kept for 60 minutes. Afterwards the zone will fall back to the standard plan defined in app or web. Value definition is like for command <i>set temperature</i>.</li>
             <li><i>temperature-for-90</i><br>
                  <b>Works on zones only.</b>
                   Sets the temperature for a zone for 90 minutes only.
                  The temperature will be kept for 90 minutes. Afterwards the zone will fall back to the standard plan defined in app or web. Value definition is like for command <i>set temperature</i>.</li>
             <li><i>temperature-for-120</i><br>
                  <b>Works on zones only.</b>
                  Sets the temperature for a zone for 120 minutes only.
                  The temperature will be kept for 120 minutes. Afterwards the zone will fall back to the standard plan defined in app or web. Value definition is like for command <i>set temperature</i>.</li>
              <li><i>temperature-for-180</i><br>
                  <b>Works on zones only.</b>
                  Sets the temperature for a zone for 180 minutes only.
                  The temperature will be kept for 180 minutes. Afterwards the zone will fall back to the standard plan defined in app or web. Value definition is like for command <i>set temperature</i>.</li>
             <li><i>temperature-for-240</i><br>
                  <b>Works on zones only.</b>
                   Sets the temperature for a zone for 240 minutes only.
                  The temperature will be kept for 240 minutes. Afterwards the zone will fall back to the standard plan defined in app or web. Value definition is like for command <i>set temperature</i>.</li>
             <li><i>temperature-for-300</i><br>
                  <b>Works on zones only.</b>
                  Sets the temperature for a zone for 300 minutes only.
                  The temperature will be kept for 300 minutes. Afterwards the zone will fall back to the standard plan defined in app or web. Value definition is like for command <i>set temperature</i>.</li>
        </ul>
    </ul>
    <br>
    <a name="TadoDeviceget"></a>
    <b>Get</b><br>
    <ul>
        <code>get &lt;name&gt; &lt;option&gt;</code>
        <br><br>
        The only available <i>get</i> function is called <b>update</b> and can be used to update all readings of the specific TadoDevice.
        <br><br>
        Options:
        <ul>
            <li><i>Update</i><br>
            <b>This <i>get</i> command is available on zones, weather and mobile devices</b>
            This call updates the readings of a <i>TadoDevie</i> with the latest values available in the Tado cloud.
            </li>
        </ul>
    </ul>
    <br>
    <a name="TadoDeviceattr"></a>
    <b>Attributes</b>
    <ul>
        <code>attr &lt;name&gt; &lt;attribute&gt; &lt;value&gt;</code>
        <br><br>
         There is one attribute available. It only affects zones.
        <br><br>
        Attributes:
        <ul>
            <li><i>earlyStart</i> true|false<br>
                When set to true the Tado system starts to heat up before the set heating change.
                The intention is to reach the target temperature right at the point in time defined.
                E.g. if you want to change the temperature from 20 degree to 22 degree on 6pm early start
                would start heating at 5:30pm so the zone is on 22 degree at 6pm.
                The early start is a feature of Tado. How this is calculated and how early the heating is started
                is up to Tado.
            </li>
        </ul>
    </ul>
</ul>


=end html

=cut
