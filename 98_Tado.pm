package main;

use strict;
use warnings;
use Data::Dumper;
use utf8;
use Encode qw( encode_utf8 );
use HttpUtils;
use JSON;


#TODO change logic from sync web handling to async


my %Tado_gets = (
update => " ",
home	=> " ",
zones	=> " ",
devices  => " ",
mobile_devices  => " ",
weather => " "
);

my %Tado_sets = (
start	=> " ",
stop => " ",
interval => " "
);

my  %url = (
getZoneTemperature     => 'https://my.tado.com/api/v2/homes/#HomeID#/zones/#ZoneID#/state?username=#Username#&password=#Password#',
setZoneTemperature     => 'https://my.tado.com/api/v2/homes/#HomeID#/zones/#ZoneID#/overlay?username=#Username#&password=#Password#',
earlyStart             => 'https://my.tado.com/api/v2/homes/#HomeID#/zones/#ZoneID#/earlyStart?username=#Username#&password=#Password#',
getZoneDetails         => 'https://my.tado.com/api/v2/homes/#HomeID#/zones?username=#Username#&password=#Password#' ,
getHomeId              => 'https://my.tado.com/api/v2/me?username=#Username#&password=#Password#',
getMobileDevices       => 'https://my.tado.com/api/v2/me?username=#Username#&password=#Password#',
getHomeDetails         =>  'https://my.tado.com/api/v2/homes/#HomeID#?username=#Username#&password=#Password#',
getWeather             =>  'https://my.tado.com/api/v2/homes/#HomeID#/weather?username=#Username#&password=#Password#',
getDevices             =>  'https://my.tado.com/api/v2/homes/#HomeID#/devices?username=#Username#&password=#Password#',
identifyDevice    		 =>  'https://my.tado.com/api/v2/devices/#DeviceId#/identify?username=#Username#&password=#Password#',
getAirComfort          =>  'https://my.tado.com/api/v2/homes/#HomeID#/airComfort?username=#Username#&password=#Password#'
);


sub Tado_Initialize($)
{
	my ($hash) = @_;

	$hash->{DefFn}      = 'Tado_Define';
	$hash->{UndefFn}    = 'Tado_Undef';
	$hash->{SetFn}      = 'Tado_Set';
	$hash->{GetFn}      = 'Tado_Get';
	$hash->{AttrFn}     = 'Tado_Attr';
	$hash->{ReadFn}     = 'Tado_Read';
	$hash->{WriteFn}    = 'Tado_Write';
	$hash->{Clients} = ':TadoDevice:';
	$hash->{MatchList} = { '1:TadoDevice'  => '^Tado;.*'};
	$hash->{AttrList} =
	'generateDevices:yes,no '
	.	'generateMobileDevices:yes,no '
	. 'generateWeather:yes,no '
	. $readingFnAttributes;

	Log 3, "Tado module initialized.";
}


sub Tado_Define($$)
{
	my ($hash, $def) = @_;
	my @param = split("[ \t]+", $def);
	my $name = $hash->{NAME};

	Log3 $name, 3, "Tado_Define $name: called ";

	my $errmsg = '';

	# Check parameter(s) - Must be min 4 in total (counts strings not purly parameter, interval is optional)
	if( int(@param) < 4 ) {
		$errmsg = return "syntax error: define <name> Tado <username> <password> [Interval]";
		Log3 $name, 1, "Tado $name: " . $errmsg;
		return $errmsg;
	}

	#Check if the username is an email address
	if ( $param[2] =~ /^.+@.+$/ ) {
		my $username = $param[2];
		$hash->{Username} = $username;
	} else {
		$errmsg = "specify valid email address within the field username. Format: define <name> Tado <username> <password> [interval]";
		Log3 $name, 1, "Tado $name: " . $errmsg;
		return $errmsg;
	}

	#Take password and use custom encryption.
	# Encryption is taken from fitbit / withings module
	my $password = tado_encrypt($param[3]);

	$hash->{Password} = $password;

	if (defined $param[4]) {
		$hash->{DEF} = sprintf("%s %s %s", InternalVal($name,'Username', undef), $password, $param[4]);
	} else {
		$hash->{DEF} = sprintf("%s %s", InternalVal($name,'Username', undef) ,$password);
	}

	#Check if interval is set and numeric.
	#If not set -> set to 60 seconds
	#If less then 5 seconds set to 5
	#If not an integer abort with failure.
	my $interval = 60;
	if (defined $param[4]) {
		if ( $param[4] =~ /^\d+$/ ) {
			$interval = $param[4];
		} else {
			$errmsg = "Specify valid integer value for interval. Whole numbers > 5 only. Format: define <name> Tado <username> <password> [interval]";
			Log3 $name, 1, "Tado $name: " . $errmsg;
			return $errmsg;
		}
	}

	if( $interval < 5 ) { $interval = 5; }
	$hash->{INTERVAL} = $interval;

	readingsSingleUpdate($hash,'state','Undefined',0);

	CommandAttr(undef,$name.' generateDevices no') if ( AttrVal($name,'generateDevices','none') eq 'none' );
	CommandAttr(undef,$name.' generateMobileDevices no') if ( AttrVal($name,'generateMobileDevices','none') eq 'none' );
	CommandAttr(undef,$name.' generateWeather no') if ( AttrVal($name,'generateWeather','none') eq 'none' );

	#Initial load of the homes
	Tado_GetHomesAndDevices($hash);

	RemoveInternalTimer($hash);

	#Call getZones with delay of 15 seconds, as all devices need to be loaded before timer triggers.
	#Otherwise some error messages are generated due to auto created devices...
	InternalTimer(gettimeofday()+15, "Tado_GetZones", $hash) if (defined $hash);

	Log3 $name, 1, sprintf("Tado_Define %s: Starting timer with interval %s", $name, InternalVal($name,'INTERVAL', undef));
	InternalTimer(gettimeofday()+ InternalVal($name,'INTERVAL', undef), "Tado_UpdateDueToTimer", $hash) if (defined $hash);
	return undef;
}


sub Tado_Undef($$)
{
	my ($hash,$arg) = @_;

	RemoveInternalTimer($hash);
	return undef;
}


sub Tado_httpSimpleOperation($$$;$)
{
	my ($hash,$url, $operation, $message) = @_;
	my ($json,$err,$data,$decoded);
	my $name = $hash->{NAME};

	my $request = {
		url           => $url,
		header        => "Content-Type:application/json;charset=UTF-8",
		method        => $operation,
		timeout       =>  2,
		hideurl       =>  1
	};

	$request->{data} = $message if (defined $message);
	Log3 $name, 5, 'Request: ' . Dumper($request);

	($err,$data)    = HttpUtils_BlockingGet($request);

	$json = "" if( !$json );
	$data = "" if( !$data );
	Log3 $name, 4, "FHEM -> Tado: " . $url;
	Log3 $name, 4, "FHEM -> Tado: " . $message if (defined $message);
	Log3 $name, 4, "Tado -> FHEM: " . $data if (defined $data);
	Log3 $name, 4, "Tado -> FHEM: Got empty response."  if (not defined $data);
	Log3 $name, 5, '$err: ' . $err;
	Log3 $name, 5, "method: " . $operation;
	Log3 $name, 2, "Something gone wrong" if( $data =~ "/tadoMode/" );

	$err = 1 if( $data =~ "/tadoMode/" );
	if (defined $data and (not $data eq '') and $operation ne 'DELETE') {
		eval {
			$decoded  = decode_json($data) if( !$err );
			Log3 $name, 5, 'Decoded: ' . Dumper($decoded);
			return $decoded;
		} or do  {
			Log3 $name, 5, 'Failure decoding: ' . $@;
		}
	} else {
		return undef;
	}
}


sub Tado_Get($@)
{
	my ( $hash, $name, @args ) = @_;

	return '"get Tado" needs at least one argument' if (int(@args) < 1);

	my $opt = shift @args;
	if(!$Tado_gets{$opt}) {
		my @cList = keys %Tado_gets;
		return "Unknown! argument $opt, choose one of " . join(" ", @cList);
	}

	my $cmd = $args[0];
	my $arg = $args[1];

	if($opt eq "home"){

		return Tado_GetHomesAndDevices($hash);

	} elsif($opt eq "zones") {

		return Tado_GetZones($hash);

	}  elsif($opt eq "devices") {

		return Tado_GetDevices($hash);

	}  elsif($opt eq "mobile_devices") {

		return Tado_GetMobileDevices($hash);

	}  elsif($opt eq "update")  {

		Log3 $name, 3, "Tado_Get $name: Updating readings for all zones";
		$hash->{LOCAL} = 1;
		Tado_RequestZoneUpdate($hash);
		Tado_RequestWeatherUpdate($hash);
		Tado_RequestMobileDeviceUpdate($hash);
		Tado_RequestAirComfortUpdate($hash);
		delete $hash->{LOCAL};

  }  elsif($opt eq "airComfortUpdate")  {

		$hash->{LOCAL} = 1;
		Tado_RequestAirComfortUpdate($hash);
		delete $hash->{LOCAL};

	}  elsif($opt eq "weather")  {

		Log3 $name, 3, "Tado_Get $name: Getting weather";
		return Tado_DefineWeatherChannel($hash);

	}  else	{

		my @cList = keys %Tado_gets;
		return "Unknown v2 argument $opt, choose one of " . join(" ", @cList);
	}
}


sub Tado_Set($@)
{
	my ($hash, $name, @param) = @_;

	return '"set $name" needs at least one argument' if (int(@param) < 1);

	my $opt = shift @param;
	my $value = join("", @param);

	if(!defined($Tado_sets{$opt})) {
		my @cList = keys %Tado_sets;
		return "Unknown argument $opt, choose one of " . join(" ", @cList);
	}

	if ($opt eq "start")	{

		readingsSingleUpdate($hash,'state','Started',0);
		RemoveInternalTimer($hash);

		$hash->{LOCAL} = 1;
		Tado_RequestZoneUpdate($hash);
		delete $hash->{LOCAL};

		InternalTimer(gettimeofday()+ InternalVal($name,'INTERVAL', undef), "Tado_UpdateDueToTimer", $hash);

		Log3 $name, 1, sprintf("Tado_Set %s: Updated readings and started timer to automatically update readings with interval %s", $name, InternalVal($name,'INTERVAL', undef));


	} elsif ($opt eq "stop"){

		RemoveInternalTimer($hash);
		Log3 $name, 1, "Tado_Set $name: Stopped the timer to automatically update readings";
		readingsSingleUpdate($hash,'state','Initialized',0);
		return undef;

	} elsif ($opt eq "interval"){

		my $interval = shift @param;

		$interval= 60 unless defined($interval);
		if( $interval < 5 ) { $interval = 5; }

		Log3 $name, 1, "Tado_Set $name: Set interval to" . $interval;

		$hash->{INTERVAL} = $interval;
	}
}


sub Tado_Attr(@)
{
	return undef;
}

sub Tado_GetHomesAndDevices($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (not defined $hash){
		my $msg = "Error on Tado_GetHomesAndDevices. Missing hash variable";
		Log3 'Tado', 1, $msg;
		return $msg;
	}

	my $readTemplate = $url{"getHomeId"};

	my $passwd = urlEncode(tado_decrypt(InternalVal($name,'Password', undef)));
	my $user = urlEncode(InternalVal($name,'Username', undef));

	$readTemplate =~ s/#Username#/$user/g;
	$readTemplate =~ s/#Password#/$passwd/g;

	my $d = Tado_httpSimpleOperation( $hash , $readTemplate, 'GET' );

	if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){

		readingsSingleUpdate($hash,'state',"Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}",1);
		return undef;

	} else {

		my $saveDeviceName = makeDeviceName($d->{homes}[0]->{name});
		readingsBeginUpdate($hash);
		readingsBulkUpdate($hash, "HomeID", $d->{homes}[0]->{id} );
		readingsBulkUpdate($hash, "HomeName", $saveDeviceName );
		readingsEndUpdate($hash, 1);

		Log3 $name, 1, "New Tado Home defined. Id: $d->{homes}[0]->{id} Name: $saveDeviceName";

		# This code should not be called, as TADO states in the FAQ they're currently just supporting one single home.
		if (scalar (@{$d->{homes}}) > 1 ){
			$saveDeviceName = makeDeviceName($d->{homes}[1]->{name});
			readingsBeginUpdate($hash);
			readingsBulkUpdate($hash, "HomeID_2", $d->{homes}[1]->{id} );
			readingsBulkUpdate($hash, "HomeName_2",  $saveDeviceName);
			readingsEndUpdate($hash, 1);

			Log3 $name, 1, "New Tado Home defined. Id: $d->{homes}[1]->{id} Name: $saveDeviceName";
		}

		readingsSingleUpdate($hash,'state','Initialized',0);
		return undef;
	}

}

sub Tado_GetZones($)
{

	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (not defined $hash){
		my $msg = "Error on Tado_GetZones. Missing hash variable";
		Log3 'Tado', 1, $msg;
		return $msg;
	}

	my $homeID = ReadingsVal ($name,"HomeID",undef);
	if (not defined $homeID) {
		my $msg = "Error on Tado_GetZones. Missing HomeID. Please define Home first.";
		Log3 'Tado', 1, $msg;
		return $msg;
	}

	my $readTemplate = $url{"getZoneDetails"};

	my $passwd = urlEncode(tado_decrypt(InternalVal($name,'Password', undef)));
	my $user = urlEncode(InternalVal($name,'Username', undef));


	$readTemplate =~ s/#HomeID#/$homeID/g;
	$readTemplate =~ s/#Username#/$user/g;
	$readTemplate =~ s/#Password#/$passwd/g;


	my $d = Tado_httpSimpleOperation( $hash , $readTemplate, 'GET'  );

	if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
		log 1, Dumper $d;
		readingsSingleUpdate($hash,"Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}",'Undefined',1);
		return undef;

	} else {

		readingsBeginUpdate($hash);

		my $ZoneCount = 0;

		my %ZoneIds = ();

		for my $item( @{$d} ){

			$ZoneCount += 1;
			readingsBulkUpdate($hash, "ZoneCount", $ZoneCount);
			Log3 $name, 4, "Tado_GetZones ($name): zonecount is $ZoneCount";

			my $deviceName = makeDeviceName($item->{name});

			if (not exists $ZoneIds{$item->{id}})
			{
				$ZoneIds{$item->{id}} = $deviceName;
			}

			Log3 'Tado', 4, "While updating zones (displays variable): ".Dumper \%ZoneIds;

			readingsBulkUpdate($hash, "Zone_" . $item->{id} . "_Name"  ,  $deviceName );

			my $code = $name ."-". $item->{id};

			if( defined($modules{TadoDevice}{defptr}{$code}) ) {

				Log3 $name, 5, "$name: id '$item->{id}' already defined as '$modules{TadoDevice}{defptr}{$code}->{NAME}'";

			} else {

				my $deviceName = "Tado_" . makeDeviceName($item->{name});
				$deviceName =~ s/ /_/g;
				my $define= "$deviceName TadoDevice $item->{id} IODev=$name";

				Log3 $name, 1, "Tado_GetZones ($name): create new device '$deviceName' for zone '$item->{id}'";

				my $cmdret= CommandDefine(undef,$define);

				if(defined $cmdret) {
					if( not index($cmdret, 'already defined') != -1) {
						Log3 $name, 1, "$name: Autocreate: An error occurred while creating device for id '$item->{id}': $cmdret";
					}
				} else {
					CommandAttr(undef,"$deviceName room Tado");
					CommandAttr(undef,"$deviceName subType zone");
				}

			}

			#Independent if the device was created or not all internals of the device must be Updated
			my $deviceHash = $modules{TadoDevice}{defptr}{$code};
			$deviceHash->{originalName} = $item->{name};
			$deviceHash->{TadoType} = $item->{Type};

			readingsSingleUpdate($deviceHash, "date_created"  , $item->{dateCreated} , 1);
			readingsSingleUpdate($deviceHash, "supports_dazzle"  , $item->{supportsDazzle}, 1 );

		}

		$hash->{ZoneIDs} = join(", ", keys %ZoneIds);
		Log3 'Tado', 3, "After Updating zones: ".Dumper InternalVal($name,'ZoneIDs', undef);
		#Log3 'Tado', 1, "Hashdump: ".Dumper $hash;
		readingsEndUpdate($hash, 1);
		return undef;

	}

}

sub Tado_GetDevices($)
{

	my ($hash) = @_;
	my $name = $hash->{NAME};


	my $isEnabled = AttrVal($name, 'generateDevices', 'yes');
	if ($isEnabled eq 'no') {
		my $msg = "Attribute 'generateDevices' is set to no. Command will not be executed.";
		Log3 'Tado', 1, $msg;
		return $msg;
	}


	my $homeID = ReadingsVal ($name,"HomeID",undef);
	if (not defined $homeID) {
		my $msg = "Error on Tado_GetDevices. Missing HomeID. Please define Home first.";
		Log3 'Tado', 1, $msg;
		return $msg;
	}

	my $readTemplate = $url{"getDevices"};

	my $passwd = urlEncode(tado_decrypt(InternalVal($name,'Password', undef)));
	my $user = urlEncode(InternalVal($name,'Username', undef));


	$readTemplate =~ s/#HomeID#/$homeID/g;
	$readTemplate =~ s/#Username#/$user/g;
	$readTemplate =~ s/#Password#/$passwd/g;


	my $d = Tado_httpSimpleOperation( $hash , $readTemplate, 'GET'  );

	if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
		log 1, Dumper $d;
		readingsSingleUpdate($hash,'state',"Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}",1);
		return undef;

	} else {


		readingsBeginUpdate($hash);


		my $count = 0;

		for my $item( @{$d} ){
			$count++;
			readingsBulkUpdate($hash, "DeviceCount", $count);
			readingsBulkUpdate($hash, "Device_".$item->{serialNo} , $item->{deviceType});

			my $code = $name ."-". $item->{serialNo};

			if( defined($modules{TadoDevice}{defptr}{$code}) )
			{
				Log3 $name, 5, "Tado_GetDevices ($name): device id '$item->{serialNo}' already defined as '$modules{TadoDevice}{defptr}{$code}->{NAME}'";
			} else {

				my $deviceName = "Tado_" . $item->{serialNo};
				$deviceName =~ s/ /_/g;
				my $define= "$deviceName TadoDevice $item->{serialNo} IODev=$name";

				Log3 $name, 1, "Tado_GetDevices ($name): create new device '$deviceName' of type '$item->{deviceType}'";

				my $cmdret= CommandDefine(undef,$define);

				if(defined $cmdret) {
					if( not index($cmdret, 'already defined') != -1) {
						Log3 $name, 1, "$name: Autocreate: An error occurred while creating device for id '$item->{id}': $cmdret";
					}
				} else {

					my $deviceHash = $modules{TadoDevice}{defptr}{$code};

					CommandAttr(undef,"$deviceName room Tado");
					if ($item->{deviceType} eq 'IB01'){
						CommandAttr(undef,"$deviceName subType bridge");
						$deviceHash->{deviceType} = $item->{deviceType};
						$deviceHash->{serialNo} = $item->{serialNo};
						$deviceHash->{shortSerialNo} = $item->{shortSerialNo};
						$deviceHash->{currentFwVersion} = $item->{currentFwVersion};
						$deviceHash->{inPairingMode} = $item->{inPairingMode};
						$deviceHash->{capabilities} = join(" ", $item->{characteristics}->{capabilities});
					} else {
						CommandAttr(undef,"$deviceName subType thermostat");
						$deviceHash->{deviceType} = $item->{deviceType};
						$deviceHash->{serialNo} = $item->{serialNo};
						$deviceHash->{shortSerialNo} = $item->{shortSerialNo};
						$deviceHash->{currentFwVersion} = $item->{currentFwVersion};
						$deviceHash->{batteryState} = $item->{inPairingMode};
						$deviceHash->{capabilities} = join(" ", $item->{characteristics}->{capabilities});
					}
				}
			}
		}
		readingsEndUpdate($hash, 1);
		return undef;
	}
}

sub Tado_GetMobileDevices($)
{

	my ($hash) = @_;
	my $name = $hash->{NAME};

	my $isEnabled = AttrVal($name, 'generateMobileDevices', 'yes');
	if ($isEnabled eq 'no') {
		my $msg = "Attribute 'generateMobileDevices' is set to no. Command 'getMobileDevices' cannot be executed.";
		Log3 'Tado', 1, $msg;
		return $msg;
	}

	my $readTemplate = $url{"getMobileDevices"};

	my $passwd = urlEncode(tado_decrypt(InternalVal($name,'Password', undef)));
	my $user = urlEncode(InternalVal($name,'Username', undef));

	$readTemplate =~ s/#Username#/$user/g;
	$readTemplate =~ s/#Password#/$passwd/g;


	my $d = Tado_httpSimpleOperation( $hash , $readTemplate, 'GET'  );

	if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
		log 1, Dumper $d;
		readingsSingleUpdate($hash,'state',"Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}",1);
		return undef;

	} else {


		readingsBeginUpdate($hash);

		my %MobileDeviceIds = ();

		my $count = 0;
		for my $item( @{$d->{mobileDevices}} ){
			$count++;
			readingsBulkUpdate($hash, "MobileDeviceCount", $count);

			readingsBulkUpdate($hash, "MobileDevice_".$item->{id} , $item->{name});

			Log3 $name, 2, "Tado_GetMobileDevices: Adding mobile device with id '$item->{id}' and name (with unsave characters) '$item->{name}'";

			if (not exists $MobileDeviceIds{$item->{id}})
			{
				$MobileDeviceIds{$item->{id}} = $item->{name};
			}

			my $code = $name ."-". $item->{id};

			if( defined($modules{TadoDevice}{defptr}{$code}) )
			{
				Log3 $name, 5, "Tado_GetMobileDevices ($name): mobiledevice id '$item->{id}' already defined as '$modules{TadoDevice}{defptr}{$code}->{NAME}'";
			} else {

				my $deviceName = "Tado_" . $item->{name};
				$deviceName =~ s/ /_/g;
				my $define= "$deviceName TadoDevice $item->{id} IODev=$name";

				Log3 $name, 1, "Tado_GetMobileDevices ($name): create new device '$deviceName'";

				my $cmdret= CommandDefine(undef,$define);

				if(defined $cmdret) {
					if( not index($cmdret, 'already defined') != -1) {
						Log3 $name, 1, "$name: Autocreate: An error occurred while creating device for id '$item->{name}': $cmdret";
					}
				} else {

					my $deviceHash = $modules{TadoDevice}{defptr}{$code};

					CommandAttr(undef,"$deviceName room Tado");
					CommandAttr(undef,"$deviceName subType mobile_device");
					$deviceHash->{device_platform} = $item->{deviceMetadata}->{platform};
					$deviceHash->{device_osVersion} = $item->{deviceMetadata}->{osVersion};
					$deviceHash->{device_locale} = $item->{deviceMetadata}->{locale};
					$deviceHash->{device_model} = $item->{deviceMetadata}->{model};
				}
			}
		}

		$hash->{MobileDeviceIDs} = join(", ", keys %MobileDeviceIds);
		Log3 'Tado', 3, "After Updating mobile device ids: ".Dumper InternalVal($name,'ZoneIds', undef);

	}


	readingsEndUpdate($hash, 1);
	Tado_RequestMobileDeviceUpdate($hash);
	return undef;
}

sub Tado_DefineWeatherChannel($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (not defined $hash){
		my $msg = "Error on Tado_DefineWeatherChannel. Missing hash variable";
		Log3 'Tado', 1, $msg;
		return $msg;

	}

	my $homeID = ReadingsVal ($name,"HomeID",undef);
	if (not defined $homeID){
		my $msg = "Error on Tado_DefineWeatherChannel. Missing HomeID. Please define Home first.";
		Log3 'Tado', 1, $msg;
		return $msg;

	}

	my $isEnabled = AttrVal($name, 'generateWeather', 'yes');
	if ($isEnabled eq 'no') {
		my $msg = "Attribute 'generateWeather' is set to no. Command will not be executed.";
		Log3 'Tado', 1, $msg;
		return $msg;
	}


	my $code = $name ."-weather";

	if( defined($modules{TadoDevice}{defptr}{$code}) ) {
		my $msg = "Tado_GetDevices ($name): weather device already defined as '$modules{TadoDevice}{defptr}{$code}->{NAME}'";
		Log3 $name, 5, $msg;
	} else {

		my $deviceName = "Tado_Weather";
		$deviceName =~ s/ /_/g;
		my $define= "$deviceName TadoDevice weather IODev=$name";

		Log3 $name, 1, "Tado_DefineWeatherChannel ($name): create new device '$deviceName'.";

		my $cmdret= CommandDefine(undef,$define);

		if(defined $cmdret) {
			if( not index($cmdret, 'already defined') != -1) {
				Log3 $name, 1, "$name: Autocreate: An error occurred while creating weather device': $cmdret";
			}
		} else {

			my $deviceHash = $modules{TadoDevice}{defptr}{$code};

			CommandAttr(undef,"$deviceName room Tado");
			CommandAttr(undef,"$deviceName subType weather");
			Tado_RequestWeatherUpdate($hash);
		}
	}
	return undef;
}

sub Tado_GetEarlyStart($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (not defined $hash){
		Log3 $name, 1, "Erro in Tado_GetEarlyStart: No zones defined. Define zones first." if (not defined InternalVal($name,'ZoneIDs', undef));
		return undef;
	}

	my $homeID = ReadingsVal ($name,"HomeID",undef);
	if (not defined $homeID) {
		my $msg = "Error on Tado_GetEarlyStart. Missing HomeID. Please define Home first.";
		Log3 'Tado', 1, $msg;
		return $msg;
	}

	Log3 $name, 3, sprintf("Getting status update on early start for %s zones.", ReadingsVal($name,'ZoneCount', undef));

	foreach my $i (split /, /,  InternalVal($name,'ZoneIDs', undef)) {

		my $readTemplate = $url{earlyStart};

		my $passwd = urlEncode(tado_decrypt(InternalVal($name,'Password', undef)));
		my $user = urlEncode(InternalVal($name,'Username', undef));

		$readTemplate =~ s/#HomeID#/$homeID/g;
		$readTemplate =~ s/#ZoneID#/$i/g;
		$readTemplate =~ s/#Username#/$user/g;
		$readTemplate =~ s/#Password#/$passwd/g;

		my $d = Tado_httpSimpleOperation( $hash , $readTemplate, 'GET'  );

		my $message = "Tado;$i;earlyStart;$d->{enabled}";

		Log3 $name, 4, "$name: trying to dispatch message: $message";
		my $found = Dispatch($hash, $message);
		Log3 $name, 4, "$name: tried to dispatch message. Result: $found";
	}
	return undef;
}

sub Tado_UpdateEarlyStartCallback($)
{
	my ($param, $err, $data) = @_;
	my $hash = $param->{hash};
	my $name = $hash->{NAME};

	if($err ne "")                                                                                                      # wenn ein Fehler bei der HTTP Abfrage aufgetreten ist
	{
		Log3 $name, 3, "error while requesting EarlyStart Information: ".$param->{url}." - $err";                                               # Eintrag fürs Log
		readingsSingleUpdate($hash, "state", "ERROR", 1);
		return undef;
	}

	Log3 $name, 3, "Received non-blocking data from TADO for weather device.";

	Log3 $name, 4, "FHEM -> Tado: " . $param->{url};
	Log3 $name, 4, "FHEM -> Tado: " . $param->{message} if (defined $param->{message});
	Log3 $name, 4, "Tado -> FHEM: " . $data;
	Log3 $name, 5, '$err: ' . $err;
	Log3 $name, 5, "method: " . $param->{method};
	Log3 $name, 2, "Something gone wrong" if( $data =~ "/tadoMode/" );

	if (!defined($data) or $param->{method} eq 'DELETE') {
		return undef;
	}

	eval {
		my $d  = decode_json($data) if( !$err );
		Log3 $name, 5, 'Decoded: ' . Dumper($d);



		if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
			log 1, Dumper $d;
			readingsSingleUpdate($hash,'state',"Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}",0);
			return undef;
		}

		my $message = "Tado;$param->{zoneID};earlyStart;$d->{enabled}";

		Log3 $name, 4, "$name: trying to dispatch message: $message";
		my $found = Dispatch($hash, $message);
		Log3 $name, 4, "$name: tried to dispatch message. Result: $found";

		return undef;

	} or do  {
		Log3 $name, 5, 'Failure decoding: ' . $@;
		return undef;
	}
}

sub Tado_RequestEarlyStartUpdate($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (not defined $hash){
		Log3 $name, 1, "Error in Tado_RequestEarlyStartUpdate: No zones defined. Define zones first." if (not defined InternalVal($name,'ZoneIDs', undef));
		return undef;
	}

	my $homeID = ReadingsVal ($name,"HomeID",undef);
	if (not defined $homeID)
	{
		my $msg = "Error on Tado_RequestEarlyStartUpdate. Missing HomeID. Please define Home first.";
		Log3 'Tado', 1, $msg;
		return $msg;
	}


	Log3 $name, 3, sprintf("Getting status update on early start for %s zones.", ReadingsVal($name,'ZoneCount', undef));

	foreach my $i (split /, /,  InternalVal($name,'ZoneIDs', undef)) {

		my $readTemplate = $url{earlyStart};

		my $passwd = urlEncode(tado_decrypt(InternalVal($name,'Password', undef)));
		my $user = urlEncode(InternalVal($name,'Username', undef));

		my $ZoneName = "Zone_" . $i . "_ID";

		$readTemplate =~ s/#HomeID#/$homeID/g;
		$readTemplate =~ s/#ZoneID#/$i/g;
		$readTemplate =~ s/#Username#/$user/g;
		$readTemplate =~ s/#Password#/$passwd/g;

		my $request = {
			url           => $readTemplate,
			header        => "Content-Type:application/json;charset=UTF-8",
			method        => 'GET',
			timeout       =>  2,
			hideurl       =>  1,
			callback      => \&Tado_UpdateEarlyStartCallback,
			hash          => $hash,
			zoneID        => $i
		};

		Log3 $name, 5, 'NonBlocking Request: ' . Dumper($request);

		HttpUtils_NonblockingGet($request);
	}
}

sub Tado_UpdateWeatherCallback($)
{
	my ($param, $err, $data) = @_;
	my $hash = $param->{hash};
	my $name = $hash->{NAME};

	if($err ne "")                                                                                                      # wenn ein Fehler bei der HTTP Abfrage aufgetreten ist
	{
		Log3 $name, 3, "error while requesting ".$param->{url}." - $err";                                               # Eintrag fürs Log
		readingsSingleUpdate($hash, "state", "ERROR", 1);
		return undef;
	}

	Log3 $name, 3, "Received non-blocking data from TADO for weather device.";

	Log3 $name, 4, "FHEM -> Tado: " . $param->{url};
	Log3 $name, 4, "FHEM -> Tado: " . $param->{message} if (defined $param->{message});
	Log3 $name, 4, "Tado -> FHEM: " . $data;
	Log3 $name, 5, '$err: ' . $err;
	Log3 $name, 5, "method: " . $param->{method};
	Log3 $name, 2, "Something gone wrong" if( $data =~ "/tadoMode/" );

	if (!defined($data) or $param->{method} eq 'DELETE') {
		return undef;
	}

	eval {
		my $d  = decode_json($data) if( !$err );
		Log3 $name, 5, 'Decoded: ' . Dumper($d);

		if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
			log 1, Dumper $d;
			readingsSingleUpdate($hash,'state',"Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}",0);
			return undef;
		}

		my $message = "Tado;weather;weather;"
		. $d->{solarIntensity}->{percentage} . ";"
		. $d->{solarIntensity}->{timestamp} . ";"
		. $d->{outsideTemperature}->{celsius} . ";"
		. $d->{outsideTemperature}->{timestamp} . ";"
		. $d->{weatherState}->{value} . ";"
		. $d->{weatherState}->{timestamp};

		Log3 $name, 4, "$name: trying to dispatch message: $message";
		my $found = Dispatch($hash, $message);
		Log3 $name, 4, "$name: tried to dispatch message. Result: $found";

		readingsBeginUpdate($hash);
		readingsBulkUpdate($hash, "LastUpdate_Weather", localtime );
		readingsEndUpdate($hash, 1);

		return undef;
	} or do  {
		Log3 $name, 5, 'Failure decoding: ' . $@;
		return undef;
	}

}

sub Tado_UpdateMobileDeviceCallback($)
{
	my ($param, $err, $data) = @_;
	my $hash = $param->{hash};
	my $name = $hash->{NAME};

	if($err ne "")                                                                                                      # wenn ein Fehler bei der HTTP Abfrage aufgetreten ist
	{
		Log3 $name, 3, "error while requesting ".$param->{url}." - $err";                                               # Eintrag fürs Log
		readingsSingleUpdate($hash, "state", "ERROR", 1);
		return undef;
	}

	Log3 $name, 3, "Received non-blocking data from TADO for mobile devices.";

	Log3 $name, 4, "FHEM -> Tado: " . $param->{url};
	Log3 $name, 4, "FHEM -> Tado: " . $param->{message} if (defined $param->{message});
	Log3 $name, 4, "Tado -> FHEM: " . $data;
	Log3 $name, 5, '$err: ' . $err;
	Log3 $name, 5, "method: " . $param->{method};
	Log3 $name, 2, "Something gone wrong" if( $data =~ "/tadoMode/" );

	if (!defined($data) or $param->{method} eq 'DELETE') {
		return undef;
	}

	eval {
		my $d  = decode_json($data) if( !$err );
		Log3 $name, 5, 'Decoded: ' . Dumper($d);

		if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
			log 1, Dumper $d;
			readingsSingleUpdate($hash,'state',"Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}",0);
			return undef;
		}

		for my $item( @{$d->{mobileDevices}} ){

			my $message = "Tado;$item->{id};locationdata;"
			. $item->{settings}->{geoTrackingEnabled}. ";";

			if ($item->{settings}->{geoTrackingEnabled})
			{
				$message .= $item->{location}->{stale}. ";"
				. $item->{location}->{atHome}. ";"
				. $item->{location}->{bearingFromHome}->{degrees}. ";"
				. $item->{location}->{bearingFromHome}->{radians}. ";";
				my $distance = $item->{location}->{relativeDistanceFromHomeFence};
				$message.=	defined $distance ? $distance.";" : ";" ;
			} else {
				$message .= ";;;;;"
			}


			if (defined $item->{settings}->{pushNotifications})
			{
				$message .= $item->{settings}->{pushNotifications}->{lowBatteryReminder}. ";"
				. $item->{settings}->{pushNotifications}->{awayModeReminder}. ";"
				. $item->{settings}->{pushNotifications}->{homeModeReminder}. ";"
				. $item->{settings}->{pushNotifications}->{openWindowReminder}. ";"
				. $item->{settings}->{pushNotifications}->{energySavingsReportReminder};
			} else {
				$message .=";;;;"
			}

			Log3 $name, 2, "$name: trying to dispatch message: $message";
			my $found = Dispatch($hash, $message);
			$found = "not dispatched" if (not defined $found);
			Log3 $name, 4, "$name: tried to dispatch message. Result: $found";
		}
		readingsBeginUpdate($hash);
		readingsBulkUpdate($hash, "LastUpdate_MobileDevices", localtime );
		readingsEndUpdate($hash, 1);

		return undef;
	} or do  {
		Log3 $name, 5, 'Failure decoding: ' . $@;
		return undef;
	}

}

sub Tado_RequestWeatherUpdate($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (not defined $hash){
		Log3 'Tado', 1, "Error on Tado_GetWeather. Missing hash variable";
		return undef;
	}

	my $homeID = ReadingsVal ($name,"HomeID",undef);
	if (not defined $homeID) {
		my $msg = "Error on Tado_RequestWeatherUpdate. Missing HomeID. Please define Home first.";
		Log3 'Tado', 1, $msg;
		return $msg;
	}

	my $isEnabled = AttrVal($name, 'generateWeather', 'yes');
	if ($isEnabled eq 'no') {
		my $msg = "Attribute 'generateWeather' is set to no. Update will not be executed.";
		Log3 'Tado', 4, $msg;
		return undef;
	}


	my $code = $name ."-weather";

	if (not defined($modules{TadoDevice}{defptr}{$code})) {
		Log3 $name, 3, "Tado_RequestWeatherUpdate ($name) : Not updating weather channel as it is not defined.";
		return undef;
	}

	Log3 $name, 4, "Tado_RequestWeatherUpdate Called. Name: $name";
	my $readTemplate = $url{getWeather};
	my $passwd = urlEncode(tado_decrypt(InternalVal($name,'Password', undef)));
	my $user = urlEncode(InternalVal($name,'Username', undef));

	$readTemplate =~ s/#HomeID#/$homeID/g;
	$readTemplate =~ s/#Username#/$user/g;
	$readTemplate =~ s/#Password#/$passwd/g;

	my $request = {
		url           => $readTemplate,
		header        => "Content-Type:application/json;charset=UTF-8",
		method        => 'GET',
		timeout       =>  2,
		hideurl       =>  1,
		callback      => \&Tado_UpdateWeatherCallback,
		hash          => $hash
	};

	Log3 $name, 5, 'NonBlocking Request: ' . Dumper($request);

	HttpUtils_NonblockingGet($request);

}

sub Tado_RequestMobileDeviceUpdate($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (not defined $hash){
		Log3 'Tado', 1, "Error on Tado_RequestMobileDeviceUpdate. Missing hash variable";
		return undef;
	}


	my $isEnabled = AttrVal($name, 'generateMobileDevices', 'yes');
	if ($isEnabled eq 'no') {
		my $msg = "Attribute 'generateMobileDevices' is set to no. No update will be executed.";
		Log3 'Tado', 3, $msg;
		return undef;
	}


	Log3 $name, 4, "Tado_RequestMobileDeviceUpdate Called. Name: $name";
	my $readTemplate = $url{getMobileDevices};
	my $passwd = urlEncode(tado_decrypt(InternalVal($name,'Password', undef)));
	my $user = urlEncode(InternalVal($name,'Username', undef));

	$readTemplate =~ s/#Username#/$user/g;
	$readTemplate =~ s/#Password#/$passwd/g;

	my $request = {
		url           => $readTemplate,
		header        => "Content-Type:application/json;charset=UTF-8",
		method        => 'GET',
		timeout       =>  2,
		hideurl       =>  1,
		callback      => \&Tado_UpdateMobileDeviceCallback,
		hash          => $hash
	};

	Log3 $name, 5, 'NonBlocking Request: ' . Dumper($request);

	HttpUtils_NonblockingGet($request);

}

sub Tado_UpdateZoneCallback($)
{
	my ($param, $err, $data) = @_;
	my $hash = $param->{hash};
	my $name = $hash->{NAME};

	if($err ne "")                                                                                                      # wenn ein Fehler bei der HTTP Abfrage aufgetreten ist
	{
		Log3 $name, 3, "error while requesting ".$param->{url}." - $err";                                               # Eintrag fürs Log
		readingsSingleUpdate($hash, "state", "ERROR", 1);
		return undef;
	}

	Log3 $name, 3, "Received non-blocking data from TADO for zone " . $param->{zoneID};

	Log3 $name, 4, "FHEM -> Tado: " . $param->{url};
	Log3 $name, 4, "FHEM -> Tado: " . $param->{message} if (defined $param->{message});
	Log3 $name, 4, "Tado -> FHEM: " . $data;
	Log3 $name, 5, '$err: ' . $err;
	Log3 $name, 5, "method: " . $param->{method};
	Log3 $name, 2, "Something gone wrong" if( $data =~ "/tadoMode/" );

	if (!defined($data) or $param->{method} eq 'DELETE') {
		return undef;
	}

	eval {
		my $d  = decode_json($data) if( !$err );
		Log3 $name, 5, 'Decoded: ' . Dumper($d);




		if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
			log 1, Dumper $d;
			readingsSingleUpdate($hash,'state',"Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}",1);
			return undef;
		}

		my $overlay =  defined $d->{overlay} ? 1 : 0;

		my $message = "Tado;$param->{zoneID};temp;";
		#measured-temp
		my $insideTempCelsius = $d->{sensorDataPoints}->{insideTemperature}->{celsius};
		$message.=	defined $insideTempCelsius ? $insideTempCelsius.";" : ";" ;
		#measured-temp-timestamp
		my $insideTempTimestamp = $d->{sensorDataPoints}->{insideTemperature}->{timestamp};
		$message.=	defined $insideTempTimestamp ? $insideTempTimestamp.";" : ";" ;
		#measured-temp-fahrenheit
		my $measuredFahrenheit = $d->{sensorDataPoints}->{insideTemperature}->{fahrenheit};
		$message.=	defined $measuredFahrenheit ? $measuredFahrenheit.";" : ";" ;

		#measured-temp-precision
		my $measuredPrecisionCelsius = $d->{sensorDataPoints}->{insideTemperature}->{precision}->{celsius};
		$message.=	defined $measuredPrecisionCelsius ? $measuredPrecisionCelsius.";" : ";" ;
		#measured-temp-precision-fahrenheit
		my $measuredPrecisionFahrenheit = $d->{sensorDataPoints}->{insideTemperature}->{precision}->{fahrenheit};
		$message.=	defined $measuredPrecisionFahrenheit ? $measuredPrecisionFahrenheit.";" : ";" ;

		#desired-temp
		if ($d->{setting}->{power} eq "OFF") {
			$message .= $d->{setting}->{power}. ";";
		} else {
			$message .=  $d->{setting}->{temperature}->{celsius}. ";";
		}

		#measured-humidity
		$message .=  $d->{sensorDataPoints}->{humidity}->{percentage} . ";"
		#measured-humidity-timestamp
		. $d->{sensorDataPoints}->{humidity}->{timestamp} . ";";
		#link
		my $link = $d->{link}->{state};
		$message.=	defined $link ? $link.";" : ";" ;



		#open-window
		if (not defined $d->{openWindow}) {
			$message .= "null;"
		} else {
			$message .= $d->{openWindow} . ";"
		}
		#heating-percentage
		my $heatingPowerTemperature = $d->{activityDataPoints}->{heatingPower}->{percentage};
		$message.=	defined $heatingPowerTemperature ? $heatingPowerTemperature.";" : ";" ;

		#heating-percentage-timestamp
		my $heatingTimestamp = $d->{activityDataPoints}->{heatingPower}->{timestamp};
		$message.=	defined $heatingTimestamp ? $heatingTimestamp.";" : ";" ;



		if (defined $d->{nextScheduleChange}){
			#nextScheduleChange-temperature
			my $nextScheduleChangeTemperature = $d->{nextScheduleChange}->{setting}->{temperature}->{celsius};
			$message.=	defined $nextScheduleChangeTemperature ? $nextScheduleChangeTemperature.";" : ";" ;
			#nextScheduleChange-power
			my $nextScheduleChangePower = $d->{nextScheduleChange}->{setting}->{power};
				$message.=	defined $nextScheduleChangePower ? $nextScheduleChangePower.";" : ";" ;
			#nextScheduleChange-start
			my $nextScheduleChangeState = $d->{nextScheduleChange}->{start};
				$message.=	defined $nextScheduleChangeState ? $nextScheduleChangeState.";" : ";" ;

		} else {
			$message .=  ";;;";
		}

		#overlay-active
		$message .= $overlay;

		if ($overlay) {
			$message .= ";"
			#overlay-mode
			. $d->{overlay}->{type} . ";"
			#overlay-power
			. $d->{overlay}->{setting}->{power} . ";";
			#overlay-desired-temperature

			if (not $d->{overlay}->{setting}->{power} eq 'OFF'){
				$message .= $d->{overlay}->{setting}->{temperature}->{celsius} . ";";
			} else {
				$message .= 'OFF;';
			}

			#overlay-termination-mode
			$message .= $d->{overlay}->{termination}->{type} . ";";
			#overlay-termination-durationInSeconds

			if (not $d->{overlay}->{termination}->{type} eq 'MANUAL'){
				$message .= $d->{overlay}->{termination}->{durationInSeconds} . ";"
				#overlay-overlay-termination-expiry
				. $d->{overlay}->{termination}->{expiry} . ";"
				#overlay-overlay-termination-remainingTimeInSeconds
				. $d->{overlay}->{termination}->{remainingTimeInSeconds};
			}

		}

		Log3 $name, 4, "$name: trying to dispatch message: $message";
		my $found = Dispatch($hash, $message);
		Log3 $name, 4, "$name: tried to dispatch message. Result: $found";

		readingsBeginUpdate($hash);
		readingsBulkUpdate($hash, "LastUpdate_Zones", localtime );
		readingsEndUpdate($hash, 1);

		return undef;
	} or do  {
		Log3 $name, 5, 'Failure decoding: ' . $@;
		return undef;
	}
}

sub Tado_UpdateAirComfortCallback($)
{
	my ($param, $err, $data) = @_;
	my $hash = $param->{hash};
	my $name = $hash->{NAME};

	if($err ne "")                                                                                                      # wenn ein Fehler bei der HTTP Abfrage aufgetreten ist
	{
		Log3 $name, 3, "error while requesting ".$param->{url}." - $err";                                               # Eintrag fürs Log
		readingsSingleUpdate($hash, "state", "ERROR", 1);
		return undef;
	}

	Log3 $name, 3, "Received non-blocking data from TADO for air quality ";

	Log3 $name, 4, "FHEM -> Tado: " . $param->{url};
	Log3 $name, 4, "FHEM -> Tado: " . $param->{message} if (defined $param->{message});
	Log3 $name, 4, "Tado -> FHEM: " . $data;
	Log3 $name, 5, '$err: ' . $err;
	Log3 $name, 5, "method: " . $param->{method};
	Log3 $name, 2, "Something gone wrong" if( $data =~ "/tadoMode/" );

	eval {
		my $d  = decode_json($data) if( !$err );
		Log3 $name, 5, 'Decoded: ' . Dumper($d);


		if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
			log 1, Dumper $d;
			readingsSingleUpdate($hash,'state',"Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}",1);
			return undef;
		}

		readingsBeginUpdate($hash);
		readingsBulkUpdate($hash, "airComfort_freshness", $d->{freshness}->{value} );
		readingsBulkUpdate($hash, "airComfort_lastWindowOpen", $d->{freshness}->{lastOpenWindow} );
		readingsEndUpdate($hash, 1);


		foreach my $param (@{$d->{comfort}})
		{
     Log3 $name, 4, "Trying to decode message: ". Dumper($param);
			my $message = "Tado;$param->{roomId};airComfort;";


		 $message .= $param->{temperatureLevel} . ";"
			. $param->{humidityLevel} . ";"
			. $param->{coordinate}->{radial} . ";"
			. $param->{coordinate}->{angular} . ";";

			Log3 $name, 4, "$name: trying to dispatch message: $message";
			my $found = Dispatch($hash, $message);
			Log3 $name, 4, "$name: tried to dispatch message. Result: $found";

		}

		readingsBeginUpdate($hash);
		readingsBulkUpdate($hash, "LastUpdate_AirComfort", localtime );
		readingsEndUpdate($hash, 1);

		return undef;
	} or do  {
		Log3 $name, 5, 'Failure decoding: ' . $@;
		return undef;
	}
}

sub Tado_UpdateDueToTimer($)
{

	my ($hash) = @_;
	my $name = $hash->{NAME};

	#local allows call of function without adding new timer.
	#must be set before call ($hash->{LOCAL} = 1) and removed after (delete $hash->{LOCAL};)
	if(!$hash->{LOCAL}) {
		RemoveInternalTimer($hash);
		#Log3 "Test", 1, Dumper($hash);
		InternalTimer(gettimeofday()+InternalVal($name,'INTERVAL', undef), "Tado_UpdateDueToTimer", $hash);
		readingsSingleUpdate($hash,'state','Polling',0);
	}

	Tado_RequestZoneUpdate($hash);
	Tado_RequestAirComfortUpdate($hash);
	Tado_RequestMobileDeviceUpdate($hash);
	Tado_RequestWeatherUpdate($hash);

}


sub Tado_RequestZoneUpdate($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (not defined $hash){
		Log3 'Tado', 1, "Error on Tado_RequestZoneUpdate. Missing hash variable";
		return undef;
	}

	if (not defined InternalVal($name,'ZoneIDs', undef)){
		Log3 'Tado', 1, "Error on Tado_RequestZoneUpdate. Missing zones. Please define zones first.";
		return undef;
	}

	my $homeID = ReadingsVal ($name,"HomeID",undef);
	if (not defined $homeID) {
		my $msg = "Error on Tado_RequestZoneUpdate. Missing HomeID. Please define Home first.";
		Log3 'Tado', 1, $msg;
		return $msg;
	}

	Log3 $name, 4, "Tado_RequestZoneUpdate Called for non-blocking value update. Name: $name";


	Log3 $name, 3, sprintf ("Getting zone update for %s zones.", ReadingsVal($name, "ZoneCount", 0 ));

	Log3 $name, 3, "Array out of zone ids: ". Dumper(split /, /,  InternalVal($name,'ZoneIDs', undef));


	foreach my $i (split /, /,  InternalVal($name,'ZoneIDs', undef)) {

		Log3 $name, 3, "Updating zone id: ". $i;

		my $readTemplate = $url{"getZoneTemperature"};

		my $passwd = urlEncode(tado_decrypt(InternalVal($name,'Password', undef)));
		my $user = urlEncode(InternalVal($name,'Username', undef));


		$readTemplate =~ s/#HomeID#/$homeID/g;
		$readTemplate =~ s/#ZoneID#/$i/g;
		$readTemplate =~ s/#Username#/$user/g;
		$readTemplate =~ s/#Password#/$passwd/g;

		my $request = {
			url           => $readTemplate,
			header        => "Content-Type:application/json;charset=UTF-8",
			method        => 'GET',
			timeout       =>  2,
			hideurl       =>  1,
			callback      => \&Tado_UpdateZoneCallback,
			hash          => $hash,
			zoneID        => $i
		};

		Log3 $name, 5, 'NonBlocking Request: ' . Dumper($request);

		HttpUtils_NonblockingGet($request);

	}

}

sub Tado_RequestAirComfortUpdate($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (not defined $hash){
		Log3 'Tado', 1, "Error on Tado_RequestAirComfortUpdate. Missing hash variable";
		return undef;
	}

	if (not defined InternalVal($name,'ZoneIDs', undef)){
		Log3 'Tado', 1, "Error on Tado_RequestAirComfortUpdate. Missing zones. Please define zones first.";
		return undef;
	}

	my $homeID = ReadingsVal ($name,"HomeID",undef);
	if (not defined $homeID) {
		my $msg = "Error on Tado_RequestAirComfortUpdate. Missing HomeID. Please define Home first.";
		Log3 'Tado', 1, $msg;
		return $msg;
	}

	Log3 $name, 4, "Tado_RequestAirComfortUpdate called for non-blocking value update. Name: $name";
	Log3 $name, 3, "Getting air comfort update.";

	my $readTemplate = $url{"getAirComfort"};

	my $passwd = urlEncode(tado_decrypt(InternalVal($name,'Password', undef)));
	my $user = urlEncode(InternalVal($name,'Username', undef));


	$readTemplate =~ s/#HomeID#/$homeID/g;
	$readTemplate =~ s/#Username#/$user/g;
	$readTemplate =~ s/#Password#/$passwd/g;

	my $request = {
		url           => $readTemplate,
		header        => "Content-Type:application/json;charset=UTF-8",
		method        => 'GET',
		timeout       =>  2,
		hideurl       =>  1,
		callback      => \&Tado_UpdateAirComfortCallback,
		hash          => $hash
	};

	Log3 $name, 5, 'NonBlocking Request: ' . Dumper($request);

	HttpUtils_NonblockingGet($request);

}


sub Tado_Write ($$)
{
	my ($hash,$code,$zoneID,$param1,$param2)= @_;
	my $name = $hash->{NAME};

	if ($code eq 'Temp')
	{
		my $duration = $param1;
		my $temperature = $param2;

		my $readTemplate = $url{"setZoneTemperature"};

		my $passwd = urlEncode(tado_decrypt(InternalVal($name,'Password', undef)));
		my $user = urlEncode(InternalVal($name,'Username', undef));

		my $homeID = ReadingsVal ($name,"HomeID",undef);

		$readTemplate =~ s/#HomeID#/$homeID/g;
		$readTemplate =~ s/#ZoneID#/$zoneID/g;
		$readTemplate =~ s/#Username#/$user/g;
		$readTemplate =~ s/#Password#/$passwd/g;


		my %message ;
		$message{'setting'}{'type'} = "HEATING";

		if (defined $temperature){
			if ($temperature eq "off") {
				$message{'setting'}{'power'} = 'OFF';
				$message{'termination'}{'durationInSeconds'} = $duration * 60;
			} else {
				$message{'setting'}{'power'} = 'ON';
				$message{'setting'}{'temperature'} {'celsius'} =  $temperature + 0 ;
			}
		}

		if ($duration eq "0") {
			$message{'termination'}{'type'}  = 'MANUAL';
		} elsif ($duration eq 'Auto') {
			Log3 $name, 4, 'Return to automatic mode';
			my $d = Tado_httpSimpleOperation( $hash , $readTemplate, 'DELETE'  );
			return undef;
		} else {
			$message{'termination'}{'type'}  = 'TIMER';
			$message{'termination'}{'durationInSeconds'} = $duration * 60;
		}

		my $d = Tado_httpSimpleOperation( $hash , $readTemplate, 'PUT',  encode_json \%message  );
		return undef;
	}

	if ($code eq 'EarlyStart')
	{
		my $setting = $param1;

		my $readTemplate = $url{"earlyStart"};

		my $passwd = urlEncode(tado_decrypt(InternalVal($name,'Password', undef)));
		my $user = urlEncode(InternalVal($name,'Username', undef));

		my $homeID = ReadingsVal ($name,"HomeID",undef);

		$readTemplate =~ s/#HomeID#/$homeID/g;
		$readTemplate =~ s/#ZoneID#/$zoneID/g;
		$readTemplate =~ s/#Username#/$user/g;
		$readTemplate =~ s/#Password#/$passwd/g;

		my %message ;
		$message{'enabled'} = $setting;

		my $d = Tado_httpSimpleOperation( $hash , $readTemplate, 'PUT' , encode_json \%message  );

		if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
			return "Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}";
		}
		return $d->{enabled};
	}

	if ($code eq 'Update')
	{
		Tado_RequestZoneUpdate($hash);
		Tado_RequestEarlyStartUpdate($hash);
		Tado_RequestWeatherUpdate($hash);
		Tado_RequestMobileDeviceUpdate($hash);
		Tado_RequestAirComfortUpdate($hash);
	}

	if ($code eq 'Hi')
	{
		my $readTemplate = $url{"identifyDevice"};
		my $passwd = urlEncode(tado_decrypt(InternalVal($name,'Password', undef)));
		my $user = urlEncode(InternalVal($name,'Username', undef));

		$readTemplate =~ s/#DeviceId#/$zoneID/g;
		$readTemplate =~ s/#Username#/$user/g;
		$readTemplate =~ s/#Password#/$passwd/g;

		my $d = Tado_httpSimpleOperation( $hash , $readTemplate, 'POST'  );

		if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
			return "Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}";
		}
		return $d->{enabled};
	}

	return undef;
}



sub tado_encrypt($)
{
	my ($decoded) = @_;
	my $key = getUniqueId();
	my $encoded;

	return $decoded if( $decoded =~ /crypt:/ );

	for my $char (split //, $decoded) {
		my $encode = chop($key);
		$encoded .= sprintf("%.2x",ord($char)^ord($encode));
		$key = $encode.$key;
	}

	return 'crypt:'.$encoded;
}

sub tado_decrypt($)
{
	my ($encoded) = @_;
	my $key = getUniqueId();
	my $decoded;

	return $encoded if( $encoded !~ /crypt:/ );

	$encoded = $1 if( $encoded =~ /crypt:(.*)/ );

	for my $char (map { pack('C', hex($_)) } ($encoded =~ /(..)/g)) {
		my $decode = chop($key);
		$decoded .= chr(ord($char)^ord($decode));
		$key = $decode.$key;
	}

	return $decoded;
}


1;

=pod
=begin html

<a name="Tado"></a>
<h3>Tado</h3>
<ul>
<i>Tado</i> implements an interface to the Tado cloud. The plugin can be used to read and write
temperature and settings from or to the Tado cloud. The communication is based on the reengineering of the protocol done by
Stephen C. Phillips. See <a href="http://blog.scphillips.com/posts/2017/01/the-tado-api-v2/">his blog</a> for more details.
Not all functions are implemented within this FHEM extension. By now the plugin is capable to
interact with the so called zones (rooms) and the registered devices. The devices cannot be
controlled directly. All interaction - like setting a temperature - must be done via the zone and not the device.
This means all configuration like the registration of new devices or the assignment of a device to a room
must be done using the Tado app or Tado website directly. Once the configuration is completed this plugin can
be used.
This device is the 'bridge device' like a HueBridge or a CUL. Per zone or device a dedicated device of type
'TadoDevice' will be created.
<br><br>
<a name="Tadodefine"></a>
<b>Define</b>
<ul>
<code>define &lt;name&gt; Tado &lt;username&gt; &lt;password&gt; &lt;interval&gt;</code>
<br><br>
Example: <code>define TadoBridge Tado mail@provider.com somepassword 120</code>
<br><br>
The username and password must match the username and password used on the Tado website.
Please be aware that username and password are stored and send as plain text. They are visible in FHEM user interface.
It is recommended to create a dedicated user account for the FHEM integration.
The Tado extension needs to pull the data from the Tado website. The 'Interval' value defines how often the value is refreshed.
</ul>
<br>
<b>Set</b><br>
<ul>
<code>set &lt;name&gt; &lt;option&gt;</code>
<br><br>
The <i>set</i> command just offers very limited options.
If can be used to control the refresh mechanism. The plugin only evaluates
the command. Any additional information is ignored.
<br><br>
Options:
<ul>
<li><i>interval</i><br>
Sets how often the values shall be refreshed.
This setting overwrites the value set during define.</li>
<li><i>start</i><br>
(Re)starts the automatic refresh.
Refresh is autostarted on define but can be stopped using stop command. Using the start command FHEM will start polling again.</li>
<li><i>stop</i><br>
Stops the automatic polling used to refresh all values.</li>
</ul>
</ul>
<br>
<a name="Tadoget"></a>
<b>Get</b><br>
<ul>
<code>get &lt;name&gt; &lt;option&gt;</code>
<br><br>
You can <i>get</i> the major information from the Tado cloud.
<br><br>
Options:
<ul>
<li><i>home</i><br>
Gets the home identifier from Tado cloud.
The home identifier is required for all further actions towards the Tado cloud.
Currently the FHEM extension only supports a single home. If you have more than one home only the first home is loaded.
<br/><b>This function is automatically executed once when a new Tado device is defined.</b></li>
<li><i>zones</i><br>
Every zone in the Tado cloud represents a room.
This command gets all zones defined for the current home.
Per zone a new FHEM device is created. The device can be used to display and
overwrite the current temperatures.
This command can always be executed to update the list of defined zones. It will not touch any existing
zone but add new zones added since last update.
<br/><b>This function is automatically executed once when a new Tado device is defined.</b></li>
</li>
<li><i>update</i><br/>
Updates the values of: <br/>
<ul>
<li>All Tado zones</li>
<li>All mobile devices - if attribute <i>generateMobileDevices</i> is set to true</li>
<li>The weather device - if attribute <i>generateWeather</i> is set to true</li>
</ul>
This command triggers a single update not a continuous refresh of the values.
</li>
<li><i>devices</i><br/>
Fetches all devices from Tado cloud and creates one TadoDevice instance
per fetched device. This command will only be executed if the attribute <i>generateDevices</i> is set to <i>yes</i>. If the attribute is set to <i>no</i> or not existing an error message will be displayed and no communication towards Tado will be done.
This command can always be executed to update the list of defined devices.
It will not touch existing devices but add new ones.
Devices will not be updated automatically as there are no values continuously changing.
</li>
<li><i>mobile_devices</i><br/>
Fetches all defined mobile devices from Tado cloud and creates one TadoDevice instance
per mobile device. This command will only be executed if the attribute <i>generateMobileDevices</i> is set to <i>yes</i>. If the attribute is set to <i>no</i> or not existing an error message will be displayed and no communication towards Tado will be done.
This command can always be executed to update the list of defined mobile devices.
It will not touch existing devices but add new ones.
</li>
<li><i>weather</i><br/>
Creates or updates an additional device for the data bridge containing the weather data provided by Tado. This command will only be executed if the attribute <i>generateWeather</i> is set to <i>yes</i>. If the attribute is set to <i>no</i> or not existing an error message will be displayed and no communication towards Tado will be done.
</li>
</ul>
</ul>
<br>
<a name="Tadoattr"></a>
<b>Attributes</b>
<ul>
<code>attr &lt;name&gt; &lt;attribute&gt; &lt;value&gt;</code>
<br><br>
You can change the behaviour of the Tado Device.
<br><br>
Attributes:
<ul>
<li><i>generateDevices</i><br>
By default the devices are not fetched and displayed in FHEM as they don't offer much functionality.
The functionality is handled by the zones not by the devices. But the devices offers an identification function <i>sayHi</i> to show a message on the specific display. If this function is required the Devices can be generated. Therefor the attribute <i>generateDevices</i> must be set to <i>yes</i>
<br/><b>If this attribute is set to <i>no</i> or if the attribute is not existing no devices will be generated..</b>
</li>
<li><i>generateMobileDevices</i><br>
By default the mobile devices are not fetched and displayed in FHEM as most users already have a person home recognition. If Tado shall be used to identify if a mobile device is at home this can be done using the mobile devices. In this case the mobile devices can be generated. Therefor the attribute <i>generateMobileDevices</i> must be set to <i>yes</i>
<br/><b>If this attribute is set to <i>no</i> or if the attribute is not existing no mobile devices will be generated..</b>
</li>
<li><i>generateWeather</i><br>
By default no weather channel is generated. If you want to use the weather as it is defined by the tado system for your specific environment you must set this attribute. If the attribute <i>generateWeather</i> is set to <i>yes</i> an additional weather channel can be generated.
<br/><b>If this attribute is set to <i>no</i> or if the attribute is not existing no Devices will be generated..</b>
</li>
</ul>
</ul>
</ul>

=end html

=cut
