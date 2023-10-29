package FHEM::Tado;

use strict;
use warnings;
use Data::Dumper;
use utf8;
use Encode qw( encode_utf8 );
use HttpUtils;
use GPUtils qw(GP_Import GP_Export);
use JSON;



## Import der FHEM Funktionen
#-- Run before package compilation
BEGIN {
    # Import from main context
    GP_Import(
        qw(
          Log3
					Log
          readingsBeginUpdate
          readingsEndUpdate
          readingsBulkUpdate
          readingsSingleUpdate
          readingFnAttributes
          InternalVal
          ReadingsVal
          RemoveInternalTimer
          InternalTimer
          HttpUtils_NonblockingGet
          HttpUtils_BlockingGet
          gettimeofday
          getUniqueId
          Attr
					AttrVal
					CommandAttr
					CommandDefine
					Dispatch
					makeDeviceName
					modules
          )
    );
}

#-- Export to main context with different name
GP_Export(
    qw(
      Initialize
      )
);



my %gets = (
update => " ",
home	=> " ",
zones	=> " ",
devices  => " ",
mobile_devices  => " ",
weather => " "
);

my %sets = (
start	=> " ",
stop => " ",
interval => " ",
presence => " ",
refreshToken  => " ",
);

my %homeAwayStatus = (
HOME	=> " ",
AWAY => " ",
);


my  %url = (
getOAuthToken          => 'https://auth.tado.com/oauth/token',
getZoneTemperature     => 'https://my.tado.com/api/v2/homes/#HomeID#/zones/#ZoneID#/state',
setZoneTemperature     => 'https://my.tado.com/api/v2/homes/#HomeID#/zones/#ZoneID#/overlay',
earlyStart             => 'https://my.tado.com/api/v2/homes/#HomeID#/zones/#ZoneID#/earlyStart',
getZoneDetails         => 'https://my.tado.com/api/v2/homes/#HomeID#/zones',
getHomeId              => 'https://my.tado.com/api/v2/me',
getMobileDevices       => 'https://my.tado.com/api/v2/homes/#HomeID#/mobileDevices',
UpdateMobileDevice     => 'https://my.tado.com/api/v2/homes/#HomeID#/mobileDevices/#DeviceId#/settings',
getHomeDetails         =>  'https://my.tado.com/api/v2/homes/#HomeID#',
getWeather             =>  'https://my.tado.com/api/v2/homes/#HomeID#/weather',
getDevices             =>  'https://my.tado.com/api/v2/homes/#HomeID#/devices',
identifyDevice    		 =>  'https://my.tado.com/api/v2/devices/#DeviceId#/identify',
getAirComfort          =>  'https://my.tado.com/api/v2/homes/#HomeID#/airComfort',
setPresenceStatus      =>  'https://my.tado.com/api/v2/homes/#HomeID#/presenceLock',
getPresenceStatus      =>  'https://my.tado.com/api/v2/homes/#HomeID#/state',
);


# OAuth Settings - Thanks to Philipp Wolfmajer (https://git.wolfmajer.at)
my %oauth = (
client_id     => 'public-api-preview',
client_secret => '4HJGRffVR8xb3XdEUQpjgZ1VplJi6Xgw',
scope         => 'home.user',
tokenFile     => "./FHEM/FhemUtils/Tado_token",
);

sub Initialize
{
	my ($hash) = @_;

	$hash->{DefFn}      = \&Define;
	$hash->{UndefFn}    = \&Undef;
	$hash->{SetFn}      = \&Set;
	$hash->{GetFn}      = \&Get;
	$hash->{AttrFn}     = \&Attr;
	$hash->{ReadFn}     = \&Read;
	$hash->{WriteFn}    = \&Write;
	$hash->{Clients} = ':TadoDevice:';
	$hash->{MatchList} = { '1:TadoDevice'  => '^Tado;.*'};
	$hash->{AttrList} =
	'generateDevices:yes,no '
	.	'generateMobileDevices:yes,no '
	. 'generateWeather:yes,no '
	. $readingFnAttributes;

	Log 3, "Tado module initialized.";
	return;
}


sub Define($$)
{
	my ($hash, $def) = @_;
	my @param = split("[ \t]+", $def);
	my $name = $hash->{NAME};

	Log3 $name, 3, "Define $name: called ";

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
	my $password = Encrypt($param[3]);

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

  GenerateAttribute($name,"generateDevices","no");
  GenerateAttribute($name,"generateMobileDevices","no");
  GenerateAttribute($name,"generateWeather","no");

	#Initial load of the homes
	GetHomesAndDevices($hash);

	RemoveInternalTimer($hash);

	#Call getZones with delay of 15 seconds, as all devices need to be loaded before timer triggers.
	#Otherwise some error messages are generated due to auto created devices...
	InternalTimer(gettimeofday()+15, "FHEM::Tado::GetZones", $hash) if (defined $hash);

	Log3 $name, 1, sprintf("Define %s: Starting timer with interval %s", $name, InternalVal($name,'INTERVAL', undef));
	InternalTimer(gettimeofday()+ InternalVal($name,'INTERVAL', undef), "FHEM::Tado::UpdateDueToTimer", $hash) if (defined $hash);
	return undef;
}


#Generate a new attribute if it is not existing yet
sub GenerateAttribute {
  my ($name, $attributeName, $value) = @_;
  CommandAttr(undef,"$name $attributeName $value") if ( AttrVal($name,$attributeName ,'none') eq 'none' );
}



sub Undef($$)
{
	my ($hash,$arg) = @_;

	RemoveInternalTimer($hash);
	return undef;
}



sub LoadToken {
    my $hash          = shift;
    my $name          = $hash->{NAME};
    my $tokenLifeTime = $hash->{TOKEN_LIFETIME};
    $tokenLifeTime = 0 if ( !defined $tokenLifeTime || $tokenLifeTime eq '' );
    my $Token = undef;

   	$Token = $hash->{'.TOKEN'} ;

        if ( $@ || $tokenLifeTime < gettimeofday() ) {
            Log3 $name, 5,
              "Tado $name" . ": "
              . "Error while loading: $@ ,requesting new one"
              if $@;
            Log3 $name, 5,
              "Tado $name" . ": " . "Token is expired, requesting new one"
              if $tokenLifeTime < gettimeofday();
            $Token = NewTokenRequest($hash);
        }
        else {
            Log3 $name, 5,
                "Tado $name" . ": "
              . "Token expires at "
              . localtime($tokenLifeTime);

            # if token is about to expire, refresh him
            if ( ( $tokenLifeTime - 45 ) < gettimeofday() ) {
                Log3 $name, 5,
                  "Tado $name" . ": " . "Token will expire soon, refreshing";
                $Token = TokenRefresh($hash);
            }
        }
        return $Token if $Token;
}

sub NewTokenRequest {
    my $hash          = shift;
    my $name          = $hash->{NAME};
	my $password =  Decrypt(InternalVal($name,'Password', undef));
	my $username =  InternalVal($name,'Username', undef);

    Log3 $name, 5, "Tado $name" . ": " . "calling NewTokenRequest()";

    my $data = {
        client_id     =>  $oauth{client_id},
        client_secret => $oauth{client_secret},
        username      => $username,
        password      => $password,
        scope         => $oauth{scope},
        grant_type    => 'password'
    };

    my $param = {
        url     => $url{getOAuthToken},
        method  => 'POST',
        timeout => 5,
        hash    => $hash,
        data    => $data
    };

    #Log3 $name, 5, 'Blocking GET: ' . Dumper($param);
    #Log3 $name, $reqDebug, "Tado $name" . ": " . "Request $AuthURL";
    my ( $err, $returnData ) = HttpUtils_BlockingGet($param);

    if ( $err ne "" ) {
        Log3 $name, 3,
            "Tado $name" . ": "
          . "NewTokenRequest: Error while requesting "
          . $param->{url}
          . " - $err";
    }
    elsif ( $returnData ne "" ) {
        Log3 $name, 5, "url " . $param->{url} . " returned: $returnData";
        my $decoded_data = eval { decode_json($returnData) };
        if ($@) {
            Log3 $name, 3, "Tado $name" . ": "
              . "NewTokenRequest: decode_json failed, invalid json. error: $@ ";
        }
        else {
            #write token data in hash
			 if (defined($decoded_data)){
              $hash->{'.TOKEN'} = $decoded_data;
            }

            # token lifetime management
            if (defined($decoded_data)){
              $hash->{TOKEN_LIFETIME} = gettimeofday() + $decoded_data->{'expires_in'};
            }
            $hash->{TOKEN_LIFETIME_HR} = localtime( $hash->{TOKEN_LIFETIME} );
            Log3 $name, 5,
                "Tado $name" . ": "
              . "Retrived new authentication token successfully. Valid until "
              . localtime( $hash->{TOKEN_LIFETIME} );
            $hash->{STATE} = "reachable";
            return $decoded_data;
        }
    }
    return;
}

sub TokenRefresh {
    my $hash          = shift;
    my $name          = $hash->{NAME};

    my $Token         = undef;

    # load token
    $Token = $hash->{'.TOKEN'};

    my $data = {
        client_id     => $oauth{client_id},
        client_secret => $oauth{client_secret},
        scope         => $oauth{scope},
        grant_type    => 'refresh_token',
        refresh_token => $Token->{'refresh_token'}
    };

    my $param = {
        url     => $url{getOAuthToken},
        method  => 'POST',
        timeout => 5,
        hash    => $hash,
        data    => $data
    };

    #Log3 $name, 5, 'Blocking GET TokenRefresh: ' . Dumper($param);
    #Log3 $name, $reqDebug, "Tado $name" . ": " . "Request $AuthURL";
    my ( $err, $returnData ) = HttpUtils_BlockingGet($param);

    if ( $err ne "" ) {
        Log3 $name, 3,
            "Tado $name" . ": "
          . "TokenRefresh: Error in token retrival while requesting "
          . $param->{url}
          . " - $err";
        $hash->{STATE} = "error";
    }

    elsif ( $returnData ne "" ) {
        Log3 $name, 5, "url " . $param->{url} . " returned: $returnData";
        my $decoded_data = eval { decode_json($returnData); };

        if ($@) {
            Log3 $name, 3,
              "Tado $name" . ": "
              . "TokenRefresh: decode_json failed, invalid json. error:$@\n"
              if $@;
            $hash->{STATE} = "error";
        }
        else {
            #write token data in file
			 if (defined($decoded_data)){
              $hash->{'.TOKEN'} = $decoded_data;

            }

            # token lifetime management
            $hash->{TOKEN_LIFETIME} =
              gettimeofday() + $decoded_data->{'expires_in'};
            $hash->{TOKEN_LIFETIME_HR} = localtime( $hash->{TOKEN_LIFETIME} );
            Log3 $name, 5,
                "Tado $name" . ": "
              . "TokenRefresh: Refreshed authentication token successfully. Valid until "
              . localtime( $hash->{TOKEN_LIFETIME} );
            $hash->{STATE} = "reachable";
            return $decoded_data;
        }
    }
    return;
}


sub httpSimpleOperationOAuth($$$;$)
{
	my ($hash,$url, $operation, $message) = @_;
	my ($json,$err,$data,$decoded);
	my $name = $hash->{NAME};
	my $CurrentTokenData = LoadToken($hash);

    Log3 $name, 3, "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}";

	my $request = {
		url           => $url,
        header => {
                 "Content-Type" => "application/json;charset=UTF-8",
                 "Authorization" => "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
                 },
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


sub Get($@)
{
	my ( $hash, $name, @args ) = @_;

	return '"get Tado" needs at least one argument' if (int(@args) < 1);

	my $opt = shift @args;
	if(!$gets{$opt}) {
		my @cList = keys %gets;
		return "Unknown! argument $opt, choose one of " . join(" ", @cList);
	}

	my $cmd = $args[0];
	my $arg = $args[1];

	if($opt eq "home"){

		return GetHomesAndDevices($hash);

	} elsif($opt eq "zones") {

		return GetZones($hash);

	}  elsif($opt eq "devices") {

		return GetDevices($hash);

	}  elsif($opt eq "mobile_devices") {

		return GetMobileDevices($hash);

	}  elsif($opt eq "update")  {

		Log3 $name, 3, "Get $name: Updating readings for all zones";
		$hash->{LOCAL} = 1;
		RequestZoneUpdate($hash);
		RequestWeatherUpdate($hash);
		RequestMobileDeviceUpdate($hash);
		RequestAirComfortUpdate($hash);
		RequestDeviceUpdate($hash);
	  RequestPresenceUpdate($hash);

		delete $hash->{LOCAL};
		return undef;

  }  elsif($opt eq "airComfortUpdate")  {

		$hash->{LOCAL} = 1;
		RequestAirComfortUpdate($hash);
		delete $hash->{LOCAL};

	}  elsif($opt eq "weather")  {

		Log3 $name, 3, "Get $name: Getting weather";
		return DefineWeatherChannel($hash);

	}  else	{

		my @cList = keys %gets;
		return "Unknown v2 argument $opt, choose one of " . join(" ", @cList);
	}
}


sub Set($@)
{
	my ($hash, $name, @param) = @_;

	return '"set $name" needs at least one argument' if (int(@param) < 1);

	my $opt = shift @param;
	my $value = join("", @param);

	if(!defined($sets{$opt})) {
		my @cList = keys %sets;
		return "Unknown argument $opt, choose one of refreshToken start stop interval presence:HOME,AWAY";
	}

	if ($opt eq "start")	{

		readingsSingleUpdate($hash,'state','Started',0);
		RemoveInternalTimer($hash);

		$hash->{LOCAL} = 1;
		RequestZoneUpdate($hash);
		delete $hash->{LOCAL};

		InternalTimer(gettimeofday()+ InternalVal($name,'INTERVAL', undef), "FHEM::Tado::UpdateDueToTimer", $hash);

		Log3 $name, 1, sprintf("Set %s: Updated readings and started timer to automatically update readings with interval %s", $name, InternalVal($name,'INTERVAL', undef));


	}    elsif ( $opt eq 'refreshToken' ) {
         Log3 $name, 3, "Tado: set $name: processing ($opt)";
         LoadToken($hash);
         Log3 $name, 3, "Tado $name" . ": " . "$opt finished\n";
     }


	elsif ($opt eq "stop"){

		RemoveInternalTimer($hash);
		Log3 $name, 1, "Set $name: Stopped the timer to automatically update readings";
		readingsSingleUpdate($hash,'state','Initialized',0);
		return undef;

	} elsif ($opt eq "interval"){

		my $interval = shift @param;

		$interval= 60 unless defined($interval);
		if( $interval < 5 ) { $interval = 5; }

		Log3 $name, 1, "Set $name: Set interval to" . $interval;

		$hash->{INTERVAL} = $interval;
	} elsif ($opt eq "presence"){


      my $status = shift @param;

			if(!$homeAwayStatus{$status}) {
				my @pList = keys %homeAwayStatus;
				return "Unknown argument $status, choose one of presence:HOME,AWAY";
				#return "Unknown argument $status, choose one of homeAwayStatus:". join(",", @pList);
			}

			WritePresenceStatus2Tado($hash,$status);


		}
			readingsSingleUpdate($hash,'state','Initialized',0);
			return undef;

}



sub Attr(@)
{
	return undef;
}

sub GetHomesAndDevices($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (not defined $hash){
		my $msg = "Error on GetHomesAndDevices. Missing hash variable";
		Log3 $name, 1, $msg;
		return $msg;
	}

	my $readTemplate = $url{"getHomeId"};
	my $d = httpSimpleOperationOAuth( $hash , $readTemplate, 'GET' );

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

sub GetZones($)
{

	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (not defined $hash){
		my $msg = "Error on GetZones. Missing hash variable";
		Log3 $name, 1, $msg;
		return $msg;
	}

	my $homeID = ReadingsVal ($name,"HomeID",undef);
	if (not defined $homeID) {
		my $msg = "Error on GetZones. Missing HomeID. Please define Home first.";
		Log3 $name, 1, $msg;
		return $msg;
	}

	my $readTemplate = $url{"getZoneDetails"};

	$readTemplate =~ s/#HomeID#/$homeID/g;

	my $d = httpSimpleOperationOAuth( $hash , $readTemplate, 'GET'  );

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
			Log3 $name, 4, "GetZones ($name): zonecount is $ZoneCount";

			my $deviceName = makeDeviceName($item->{name});

			if (not exists $ZoneIds{$item->{id}})
			{
				$ZoneIds{$item->{id}} = $deviceName;
			}

			Log3 $name, 4, "While updating zones (displays variable): ".Dumper \%ZoneIds;

			readingsBulkUpdate($hash, "Zone_" . $item->{id} . "_Name"  ,  $deviceName );

			my $code = $name ."-". $item->{id};

			if( defined($modules{TadoDevice}{defptr}{$code}) ) {

				Log3 $name, 5, "$name: id '$item->{id}' already defined as '$modules{TadoDevice}{defptr}{$code}->{NAME}'";

			} else {

				my $deviceName = "Tado_" . makeDeviceName($item->{name});
				$deviceName =~ s/ /_/g;
				my $define= "$deviceName TadoDevice $item->{id} IODev=$name";

				Log3 $name, 1, "GetZones ($name): create new device '$deviceName' for zone '$item->{id}'";

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

 		 if	(length $item->{dateCreated}) {
				readingsSingleUpdate($deviceHash, "date_created"  , $item->{dateCreated} , 1);
			}

 		 if	(length $item->{supportsDazzle}) {
			 	readingsSingleUpdate($deviceHash, "supports_dazzle"  , $item->{supportsDazzle}, 1 );
			}

		}

		$hash->{ZoneIDs} = join(", ", keys %ZoneIds);
		Log3 $name, 3, "After Updating zones: ".Dumper InternalVal($name,'ZoneIDs', undef);
		#Log3 $name, 1, "Hashdump: ".Dumper $hash;
		readingsEndUpdate($hash, 1);
		return undef;

	}

}

sub GetDevices($)
{

	my ($hash) = @_;
	my $name = $hash->{NAME};


	my $isEnabled = AttrVal($name, 'generateDevices', 'yes');
	if ($isEnabled eq 'no') {
		my $msg = "Attribute 'generateDevices' is set to no. Command will not be executed.";
		Log3 $name, 1, $msg;
		return $msg;
	}


	my $homeID = ReadingsVal ($name,"HomeID",undef);
	if (not defined $homeID) {
		my $msg = "Error on GetDevices. Missing HomeID. Please define Home first.";
		Log3 $name, 1, $msg;
		return $msg;
	}

	my $readTemplate = $url{"getDevices"};
	$readTemplate =~ s/#HomeID#/$homeID/g;

	my $d = httpSimpleOperationOAuth( $hash , $readTemplate, 'GET'  );

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

			my $code = $name ."-". $item->{serialNo};

			if( defined($modules{TadoDevice}{defptr}{$code}) )
			{
				Log3 $name, 5, "GetDevices ($name): device id '$item->{serialNo}' already defined as '$modules{TadoDevice}{defptr}{$code}->{NAME}'";
			} else {

				my $deviceName = "Tado_" . $item->{serialNo};
				$deviceName =~ s/ /_/g;
				my $define= "$deviceName TadoDevice $item->{serialNo} IODev=$name";

				Log3 $name, 1, "GetDevices ($name): create new device '$deviceName' of type '$item->{deviceType}'";

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
						$deviceHash->{capabilities} = join(' ', $item->{characteristics}->{capabilities});
					} else {
						CommandAttr(undef,"$deviceName subType thermostat");
						$deviceHash->{deviceType} = $item->{deviceType};
						$deviceHash->{serialNo} = $item->{serialNo};
						$deviceHash->{shortSerialNo} = $item->{shortSerialNo};
						$deviceHash->{capabilities} = join(' ', $item->{characteristics}->{capabilities});
					}
				}
			}
		}
		readingsEndUpdate($hash, 1);
		return undef;
	}

	RequestDeviceUpdate($hash);

}

sub GetMobileDevices($)
{

	my ($hash) = @_;
	my $name = $hash->{NAME};

	my $isEnabled = AttrVal($name, 'generateMobileDevices', 'yes');
	if ($isEnabled eq 'no') {
		my $msg = "Attribute 'generateMobileDevices' is set to no. Command 'getMobileDevices' cannot be executed.";
		Log3 $name, 1, $msg;
		return $msg;
	}

	my $homeID = ReadingsVal ($name,"HomeID",undef);
	if (not defined $homeID) {
		my $msg = "Error on GetEarlyStart. Missing HomeID. Please define Home first.";
		Log3 $name, 1, $msg;
		return $msg;
	}

	my $readTemplate = $url{"getMobileDevices"};
	$readTemplate =~ s/#HomeID#/$homeID/g;
	my $d = httpSimpleOperationOAuth( $hash , $readTemplate, 'GET'  );

	if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
		log 1, Dumper $d;
		readingsSingleUpdate($hash,'state',"Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}",1);
		return undef;

	} else {


		readingsBeginUpdate($hash);

		my %MobileDeviceIds = ();

		my $count = 0;
		for my $item( @{$d} ){
			$count++;
			readingsBulkUpdate($hash, "MobileDeviceCount", $count);

			readingsBulkUpdate($hash, "MobileDevice_".$item->{id} , $item->{name});

			Log3 $name, 2, "GetMobileDevices: Adding mobile device with id '$item->{id}' and name (with unsave characters) '$item->{name}'";

			if (not exists $MobileDeviceIds{$item->{id}})
			{
				$MobileDeviceIds{$item->{id}} = $item->{name};
			}

			my $code = $name ."-". $item->{id};

			if( defined($modules{TadoDevice}{defptr}{$code}) )
			{
				Log3 $name, 5, "GetMobileDevices ($name): mobiledevice id '$item->{id}' already defined as '$modules{TadoDevice}{defptr}{$code}->{NAME}'";
			} else {

				my $deviceName = "Tado_" . $item->{name};
				$deviceName =~ s/ /_/g;
				my $define= "$deviceName TadoDevice $item->{id} IODev=$name";

				Log3 $name, 1, "GetMobileDevices ($name): create new device '$deviceName'";

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
		Log3 $name, 3, "After Updating mobile device ids: ".Dumper InternalVal($name,'ZoneIds', undef);

	}


	readingsEndUpdate($hash, 1);
	RequestMobileDeviceUpdate($hash);
	return undef;
}

sub DefineWeatherChannel($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (not defined $hash){
		my $msg = "Error on DefineWeatherChannel. Missing hash variable";
		Log3 $name, 1, $msg;
		return $msg;

	}

	my $homeID = ReadingsVal ($name,"HomeID",undef);
	if (not defined $homeID){
		my $msg = "Error on DefineWeatherChannel. Missing HomeID. Please define Home first.";
		Log3 $name, 1, $msg;
		return $msg;

	}

	my $isEnabled = AttrVal($name, 'generateWeather', 'yes');
	if ($isEnabled eq 'no') {
		my $msg = "Attribute 'generateWeather' is set to no. Command will not be executed.";
		Log3 $name, 1, $msg;
		return $msg;
	}


	my $code = $name ."-weather";

	if( defined($modules{TadoDevice}{defptr}{$code}) ) {
		my $msg = "GetDevices ($name): weather device already defined as '$modules{TadoDevice}{defptr}{$code}->{NAME}'";
		Log3 $name, 5, $msg;
	} else {

		my $deviceName = "Tado_Weather";
		$deviceName =~ s/ /_/g;
		my $define= "$deviceName TadoDevice weather IODev=$name";

		Log3 $name, 1, "DefineWeatherChannel ($name): create new device '$deviceName'.";

		my $cmdret= CommandDefine(undef,$define);

		if(defined $cmdret) {
			if( not index($cmdret, 'already defined') != -1) {
				Log3 $name, 1, "$name: Autocreate: An error occurred while creating weather device': $cmdret";
			}
		} else {

			my $deviceHash = $modules{TadoDevice}{defptr}{$code};

			CommandAttr(undef,"$deviceName room Tado");
			CommandAttr(undef,"$deviceName subType weather");
			RequestWeatherUpdate($hash);
		}
	}
	return undef;
}

sub GetEarlyStart($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (not defined $hash){
		Log3 $name, 1, "Erro in GetEarlyStart: No zones defined. Define zones first." if (not defined InternalVal($name,'ZoneIDs', undef));
		return undef;
	}

	my $homeID = ReadingsVal ($name,"HomeID",undef);
	if (not defined $homeID) {
		my $msg = "Error on GetEarlyStart. Missing HomeID. Please define Home first.";
		Log3 $name, 1, $msg;
		return $msg;
	}

	Log3 $name, 3, sprintf("Getting status update on early start for %s zones.", ReadingsVal($name,'ZoneCount', undef));

	foreach my $i (split /, /,  InternalVal($name,'ZoneIDs', undef)) {

		my $readTemplate = $url{earlyStart};

		$readTemplate =~ s/#HomeID#/$homeID/g;
		$readTemplate =~ s/#ZoneID#/$i/g;

		my $d = httpSimpleOperationOAuth( $hash , $readTemplate, 'GET'  );

		my $message = "Tado;$i;earlyStart;$d->{enabled}";

		Log3 $name, 4, "$name: trying to dispatch message: $message";
		my $found = Dispatch($hash, $message);
		Log3 $name, 4, "$name: tried to dispatch message. Result: $found";
	}
	return undef;
}



sub UpdateEarlyStartCallback($)
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

sub RequestEarlyStartUpdate($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (not defined $hash){
		Log3 $name, 1, "Error in RequestEarlyStartUpdate: No zones defined. Define zones first." if (not defined InternalVal($name,'ZoneIDs', undef));
		return undef;
	}

	my $homeID = ReadingsVal ($name,"HomeID",undef);
	if (not defined $homeID)
	{
		my $msg = "Error on RequestEarlyStartUpdate. Missing HomeID. Please define Home first.";
		Log3 $name, 1, $msg;
		return $msg;
	}


	Log3 $name, 3, sprintf("Getting status update on early start for %s zones.", ReadingsVal($name,'ZoneCount', undef));

	foreach my $i (split /, /,  InternalVal($name,'ZoneIDs', undef)) {

		my $readTemplate = $url{earlyStart};
		my $ZoneName = "Zone_" . $i . "_ID";

		$readTemplate =~ s/#HomeID#/$homeID/g;
		$readTemplate =~ s/#ZoneID#/$i/g;

	    my $CurrentTokenData = LoadToken($hash);

		my $request = {
			url           => $readTemplate,
            header => {
                 "Content-Type" => "application/json;charset=UTF-8",
                 "Authorization" => "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
                 },
			method        => 'GET',
			timeout       =>  2,
			hideurl       =>  1,
			callback      => \&UpdateEarlyStartCallback,
			hash          => $hash,
			zoneID        => $i
		};

		Log3 $name, 5, 'NonBlocking Request: ' . Dumper($request);

		HttpUtils_NonblockingGet($request);
	}
}

sub UpdateWeatherCallback($)
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


sub UpdatePresenceCallback($)
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

	Log3 $name, 3, "Received non-blocking data from TADO for devices.";

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
		Log3 $name, 4, 'Decoded: ' . Dumper($d);

		if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
			log 1, Dumper $d;
			readingsSingleUpdate($hash,'state',"Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}",0);
			return undef;
		}

		readingsBeginUpdate($hash);
		readingsBulkUpdate($hash, "Presence", $d->{presence} );
		readingsEndUpdate($hash, 1);

		return undef;
	} or do  {
		Log3 $name, 5, 'Failure decoding: ' . $@;
		return undef;
	}

}


sub UpdateDeviceCallback($)
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

	Log3 $name, 3, "Received non-blocking data from TADO for devices.";

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
		Log3 $name, 4, 'Decoded: ' . Dumper($d);

		if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
			log 1, Dumper $d;
			readingsSingleUpdate($hash,'state',"Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}",0);
			return undef;
		}



		for my $item( @{$d} ){

      my $deviceId = "$item->{serialNo}";
			my $message = "Tado;$deviceId;devicedata;";

				my $currentFwVersion = $item->{currentFwVersion};
				$message.=      defined $currentFwVersion ? $currentFwVersion.";" : ";" ;
				my $inPairingMode = $item->{inPairingMode};
				$message.=      defined $inPairingMode ? $inPairingMode.";" : ";" ;
				my $batteryState = $item->{batteryState};
				$message.=      defined $batteryState ? $batteryState.";" : ";" ;
				my $connectionStateValue = $item->{connectionState}->{value};
				$message.=      defined $connectionStateValue ? $connectionStateValue.";" : ";" ;
				my $connectionStateTimestamp = $item->{connectionState}->{timestamp};
				$message.=      defined $connectionStateTimestamp ? $connectionStateTimestamp.";" : ";" ;

			Log3 $name, 4, "$name: trying to dispatch message: $message";
			my $found = Dispatch($hash, $message);
			$found = "not dispatched" if (not defined $found);
			Log3 $name, 4, "$name: tried to dispatch message. Result: $found";
		}

		readingsBeginUpdate($hash);
		readingsBulkUpdate($hash, "LastUpdate_Devices", localtime );
		readingsEndUpdate($hash, 1);

		return undef;
	} or do  {
		Log3 $name, 5, 'Failure decoding: ' . $@;
		return undef;
	}

}

sub UpdateMobileDeviceCallback($)
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

		for my $item( @{$d} ){

			my $message = "Tado;$item->{id};locationdata;"
			. $item->{settings}->{geoTrackingEnabled}. ";";

			if ($item->{settings}->{geoTrackingEnabled})
			{

				my $locationStale = $item->{location}->{stale};
				$message.=      defined $locationStale ? $locationStale.";" : ";" ;
				my $locationAtHome = $item->{location}->{atHome};
				$message.=      defined $locationAtHome ? $locationAtHome.";" : ";" ;
				my $locationDegrees = $item->{location}->{bearingFromHome}->{degrees};
				$message.=      defined $locationDegrees ? $locationDegrees.";" : ";" ;
				my $locationRadians = $item->{location}->{bearingFromHome}->{radians};
				$message.=      defined $locationRadians ? $locationRadians.";" : ";" ;
				my $locationDistance = $item->{location}->{relativeDistanceFromHomeFence};
				$message.=      defined $locationDistance ? $locationDistance.";" : ";" ;

			} else {
				$message .= ";;;;;"
			}


			if (defined $item->{settings}->{pushNotifications})
			{
				$message .= $item->{settings}->{pushNotifications}->{lowBatteryReminder}. ";"
				. $item->{settings}->{pushNotifications}->{awayModeReminder}. ";"
				. $item->{settings}->{pushNotifications}->{homeModeReminder}. ";"
				. $item->{settings}->{pushNotifications}->{openWindowReminder}. ";"
				. $item->{settings}->{pushNotifications}->{energySavingsReportReminder}.";";
				my $val = $item->{settings}->{pushNotifications}->{incidentDetection};
				$message.=      defined $val ? $val.";" : ";" ;
				$val = $item->{settings}->{pushNotifications}->{energyIqReminder};
				$message.=      defined $val ? $val.";" : ";" ;
			} else {
				$message .=";;;;;;;"
			}


			if (defined $item->{deviceMetadata})
			{
				my $devicePlatform = $item->{deviceMetadata}->{platform};
				$message.=      defined $devicePlatform ? $devicePlatform.";" : ";" ;
				my $deviceOs = $item->{deviceMetadata}->{osVersion};
				$message.=      defined $deviceOs ? $deviceOs.";" : ";" ;
				my $deviceModel = $item->{deviceMetadata}->{model};
				$message.=      defined $deviceModel ? $deviceModel.";" : ";" ;
				my $deviceLocale = $item->{deviceMetadata}->{locale};
				$message.=      defined $deviceLocale ? $deviceLocale.";" : ";" ;
			} else {
				$message .=";;;;"
			}

			my $specialOffersEnabled = $item->{settings}->{specialOffersEnabled};
			$message.=      defined $specialOffersEnabled ? $specialOffersEnabled.";" : ";" ;
			my $onDemandLogRetrievalEnabled = $item->{settings}->{onDemandLogRetrievalEnabled};
			$message.=      defined $onDemandLogRetrievalEnabled ? $onDemandLogRetrievalEnabled.";" : ";" ;

			Log3 $name, 4, "$name: trying to dispatch message: $message";
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

sub RequestWeatherUpdate($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (not defined $hash){
		Log3 $name, 1, "Error on GetWeather. Missing hash variable";
		return undef;
	}

	my $homeID = ReadingsVal ($name,"HomeID",undef);
	if (not defined $homeID) {
		my $msg = "Error on RequestWeatherUpdate. Missing HomeID. Please define Home first.";
		Log3 $name, 1, $msg;
		return $msg;
	}

	my $isEnabled = AttrVal($name, 'generateWeather', 'yes');
	if ($isEnabled eq 'no') {
		my $msg = "Attribute 'generateWeather' is set to no. Update will not be executed.";
		Log3 $name, 4, $msg;
		return undef;
	}


	my $code = $name ."-weather";

	if (not defined($modules{TadoDevice}{defptr}{$code})) {
		Log3 $name, 3, "RequestWeatherUpdate ($name) : Not updating weather channel as it is not defined.";
		return undef;
	}

	Log3 $name, 4, "RequestWeatherUpdate Called. Name: $name";
	my $readTemplate = $url{getWeather};
	my $CurrentTokenData = LoadToken($hash);

	$readTemplate =~ s/#HomeID#/$homeID/g;

	my $request = {
		url           => $readTemplate,
        header => {
                 "Content-Type" => "application/json;charset=UTF-8",
                 "Authorization" => "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
                 },
		method        => 'GET',
		timeout       =>  2,
		hideurl       =>  1,
		callback      => \&UpdateWeatherCallback,
		hash          => $hash
	};

	Log3 $name, 5, 'NonBlocking Request: ' . Dumper($request);

	HttpUtils_NonblockingGet($request);

}

sub RequestDeviceUpdate($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (not defined $hash){
		Log3 $name, 1, "Error on RequestDeviceUpdate. Missing hash variable";
		return undef;
	}

	my $isEnabled = AttrVal($name, 'generateDevices', 'yes');
	if ($isEnabled eq 'no') {
		my $msg = "Attribute 'generateDevices' is set to no. No update will be executed.";
		Log3 $name, 3, $msg;
		return undef;
	}

	my $homeID = ReadingsVal ($name,"HomeID",undef);
	if (not defined $homeID) {
		my $msg = "Error on RequestDeviceUpdate. Missing HomeID. Please define Home first.";
		Log3 $name, 1, $msg;
		return $msg;
	}



	Log3 $name, 4, "RequestDeviceUpdate Called. Name: $name";
	my $readTemplate = $url{getDevices};
	my $CurrentTokenData = LoadToken($hash);

	$readTemplate =~ s/#HomeID#/$homeID/g;

	my $request = {
		url           => $readTemplate,
        header => {
                 "Content-Type" => "application/json;charset=UTF-8",
                 "Authorization" => "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
                 },
		method        => 'GET',
		timeout       =>  2,
		hideurl       =>  1,
		callback      => \&UpdateDeviceCallback,
		hash          => $hash
	};

	Log3 $name, 5, 'NonBlocking Request: ' . Dumper($request);

	HttpUtils_NonblockingGet($request);

}

sub RequestPresenceUpdate($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (not defined $hash){
		Log3 $name, 1, "Error on RequestPresenceUpdate. Missing hash variable";
		return undef;
	}


	my $homeID = ReadingsVal ($name,"HomeID",undef);
	if (not defined $homeID) {
		my $msg = "Error on RequestPresenceUpdate. Missing HomeID. Please define Home first.";
		Log3 $name, 1, $msg;
		return $msg;
	}



	Log3 $name, 4, "RequestPresenceUpdate Called. Name: $name";
	my $readTemplate = $url{getPresenceStatus};
	my $CurrentTokenData = LoadToken($hash);

	$readTemplate =~ s/#HomeID#/$homeID/g;

	my $request = {
		url           => $readTemplate,
        header => {
                 "Content-Type" => "application/json;charset=UTF-8",
                 "Authorization" => "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
                 },
		method        => 'GET',
		timeout       =>  2,
		hideurl       =>  1,
		callback      => \&UpdatePresenceCallback,
		hash          => $hash
	};

	Log3 $name, 5, 'NonBlocking Request: ' . Dumper($request);

	HttpUtils_NonblockingGet($request);

}

sub RequestMobileDeviceUpdate($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (not defined $hash){
		Log3 $name, 1, "Error on RequestMobileDeviceUpdate. Missing hash variable";
		return undef;
	}


	my $isEnabled = AttrVal($name, 'generateMobileDevices', 'yes');
	if ($isEnabled eq 'no') {
		my $msg = "Attribute 'generateMobileDevices' is set to no. No update will be executed.";
		Log3 $name, 3, $msg;
		return undef;
	}

	my $homeID = ReadingsVal ($name,"HomeID",undef);
	if (not defined $homeID) {
		my $msg = "Error on GetEarlyStart. Missing HomeID. Please define Home first.";
		Log3 $name, 1, $msg;
		return $msg;
	}


	Log3 $name, 4, "RequestMobileDeviceUpdate Called. Name: $name";
	my $readTemplate = $url{getMobileDevices};
	$readTemplate =~ s/#HomeID#/$homeID/g;
	my $CurrentTokenData = LoadToken($hash);

	my $request = {
		url           => $readTemplate,
        header => {
                 "Content-Type" => "application/json;charset=UTF-8",
                 "Authorization" => "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
                 },
		method        => 'GET',
		timeout       =>  2,
		hideurl       =>  1,
		callback      => \&UpdateMobileDeviceCallback,
		hash          => $hash
	};

	Log3 $name, 5, 'NonBlocking Request: ' . Dumper($request);

	HttpUtils_NonblockingGet($request);

}

sub UpdateZoneCallback($)
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
		my $measuredHumidity = $d->{sensorDataPoints}->{humidity}->{percentage};
		$message.=      defined $measuredHumidity ? $measuredHumidity.";" : ";" ;
		#measured-humidity-timestamp
		my $measuredHumidityTimestamp = $d->{sensorDataPoints}->{humidity}->{timestamp};
		$message.=      defined $measuredHumidityTimestamp ? $measuredHumidityTimestamp.";" : ";" ;


		#link
		my $link = $d->{link}->{state};
		$message.=	defined $link ? $link.";" : ";" ;



		#open-window
		if (not defined $d->{openWindow}) {
			$message .= "null;"
		} else {
			$message .= $d->{openWindow} . ";"
		}

    #open-window
		if (not defined $d->{openWindowDetected}) {
			$message .= "false;"
		} else {
			$message .= $d->{openWindowDetected} . ";"
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

		#tado-mode
		if (not defined $d->{tadoMode}) {
			$message .= "null;"
		} else {
			$message .= $d->{tadoMode} . ";"
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

				#overlay-overlay-durationInSeconds
				my $overlayDurationInSeconds = $d->{overlay}->{termination}->{durationInSeconds};
				$message .= defined $overlayDurationInSeconds ? $overlayDurationInSeconds.";" : ";";

				#overlay-overlay-termination-expiry
				my $overlayExpiry = $d->{overlay}->{termination}->{expiry};
				$message .= defined $overlayExpiry ? $overlayExpiry.";" : ";";

				#overlay-overlay-termination-remainingTimeInSeconds
				my $overlayRemainingTimeInSeconds = $d->{overlay}->{termination}->{remainingTimeInSeconds};
				$message .= defined $overlayRemainingTimeInSeconds ? $overlayRemainingTimeInSeconds.";" : ";";

			} else {
				$message .=  ";;;";
			}

		# No overlay active - all values null
		} else {
				$message .= ";;;;;;;"
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

sub UpdateAirComfortCallback($)
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

sub UpdateDueToTimer($)
{

	my ($hash) = @_;
	my $name = $hash->{NAME};

	#local allows call of function without adding new timer.
	#must be set before call ($hash->{LOCAL} = 1) and removed after (delete $hash->{LOCAL};)
	if(!$hash->{LOCAL}) {
		RemoveInternalTimer($hash);
		#Log3 "Test", 1, Dumper($hash);
		InternalTimer(gettimeofday()+InternalVal($name,'INTERVAL', undef), "FHEM::Tado::UpdateDueToTimer", $hash);
		readingsSingleUpdate($hash,'state','Polling',0);
	}

	RequestZoneUpdate($hash);
	RequestAirComfortUpdate($hash);
	RequestMobileDeviceUpdate($hash);
	RequestWeatherUpdate($hash);

	RequestDeviceUpdate($hash);
	RequestPresenceUpdate($hash);

}

sub RequestZoneUpdate($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (not defined $hash){
		Log3 $name, 1, "Error on RequestZoneUpdate. Missing hash variable";
		return undef;
	}

	if (not defined InternalVal($name,'ZoneIDs', undef)){
		Log3 $name, 1, "Error on RequestZoneUpdate. Missing zones. Please define zones first.";
		return undef;
	}

	my $homeID = ReadingsVal ($name,"HomeID",undef);
	if (not defined $homeID) {
		my $msg = "Error on RequestZoneUpdate. Missing HomeID. Please define Home first.";
		Log3 $name, 1, $msg;
		return $msg;
	}

	Log3 $name, 4, "RequestZoneUpdate Called for non-blocking value update. Name: $name";


	Log3 $name, 3, sprintf ("Getting zone update for %s zones.", ReadingsVal($name, "ZoneCount", 0 ));

	Log3 $name, 3, "Array out of zone ids: ". Dumper(split /, /,  InternalVal($name,'ZoneIDs', undef));


	foreach my $i (split /, /,  InternalVal($name,'ZoneIDs', undef)) {

		Log3 $name, 3, "Updating zone id: ". $i;

		my $readTemplate = $url{"getZoneTemperature"};

	   my $CurrentTokenData = LoadToken($hash);

		$readTemplate =~ s/#HomeID#/$homeID/g;
		$readTemplate =~ s/#ZoneID#/$i/g;

		my $request = {
			url           => $readTemplate,
            header => {
                 "Content-Type" => "application/json;charset=UTF-8",
                 "Authorization" => "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
                 },
			method        => 'GET',
			timeout       =>  2,
			hideurl       =>  1,
			callback      => \&UpdateZoneCallback,
			hash          => $hash,
			zoneID        => $i
		};

		Log3 $name, 5, 'NonBlocking Request: ' . Dumper($request);

		HttpUtils_NonblockingGet($request);

	}

}

sub RequestAirComfortUpdate($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (not defined $hash){
		Log3 $name, 1, "Error on RequestAirComfortUpdate. Missing hash variable";
		return undef;
	}

	if (not defined InternalVal($name,'ZoneIDs', undef)){
		Log3 $name, 1, "Error on RequestAirComfortUpdate. Missing zones. Please define zones first.";
		return undef;
	}

	my $homeID = ReadingsVal ($name,"HomeID",undef);
	if (not defined $homeID) {
		my $msg = "Error on RequestAirComfortUpdate. Missing HomeID. Please define Home first.";
		Log3 $name, 1, $msg;
		return $msg;
	}

	Log3 $name, 4, "RequestAirComfortUpdate called for non-blocking value update. Name: $name";
	Log3 $name, 3, "Getting air comfort update.";

	my $readTemplate = GetMessageTemplate($hash, "getAirComfort" );
	my $CurrentTokenData = LoadToken($hash);


	my $request = {
		url           => $readTemplate,
        header => {
                 "Content-Type" => "application/json;charset=UTF-8",
                 "Authorization" => "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
                 },
		method        => 'GET',
		timeout       =>  2,
		hideurl       =>  1,
		callback      => \&UpdateAirComfortCallback,
		hash          => $hash
	};

	Log3 $name, 5, 'NonBlocking Request: ' . Dumper($request);

	HttpUtils_NonblockingGet($request);

}







sub Write ($$)
{
	my ($hash, $code, $zoneID, @params) = @_;

	my $name = $hash->{NAME};

	if ($code eq 'Temp')
	{
	   return WriteTemperature2Tado($hash, $zoneID, @params);
	}

	if ($code eq 'EarlyStart')
	{
    return WriteEarlyStart2Tado($hash, $zoneID, @params);
	}

	if ($code =~ 'geoTrackingEnabled|onDemandLogRetrievalEnabled|specialOffersEnabled')
	{
    return WriteMobileSettings2Tado($hash, $zoneID, $code, @params);

	}

	if ($code eq 'pushNotifications')
	{
    return WriteMobilePushNotificationSettings2Tado($hash, $zoneID, @params);
	}

	if ($code eq 'Update')
	{
		RequestZoneUpdate($hash);
		RequestEarlyStartUpdate($hash);
		RequestWeatherUpdate($hash);
		RequestMobileDeviceUpdate($hash);
		RequestAirComfortUpdate($hash);
		RequestDeviceUpdate($hash);

	}

	if ($code eq 'Hi')
	{
    return WriteHiRequest2Tado ($hash, $zoneId, @params);
	}

	return undef;
}

sub WriteTemperature2Tado {

    my ($hash, $zoneID, $duration, $temperature) = @_;
    my $name = $hash->{NAME};

    my $readTemplate = GetMessageTemplate( $hash, "setZoneTemperature", $zoneID );

		my %message;
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
			my $d = httpSimpleOperationOAuth( $hash , $readTemplate, 'DELETE'  );
			return undef;
		} else {
			$message{'termination'}{'type'}  = 'TIMER';
			$message{'termination'}{'durationInSeconds'} = $duration * 60;
		}

		my $d = httpSimpleOperationOAuth( $hash , $readTemplate, 'PUT',  encode_json \%message  );
		return undef;
}

sub WriteEarlyStart2Tado{

  my ($hash, $zoneID, $setting) = @_;
  my $name = $hash->{NAME};

  my $readTemplate = GetMessageTemplate( $hash, "earlyStart", $zoneID );

  my %message ;
  $message{'enabled'} = $setting;

  my $d = httpSimpleOperationOAuth( $hash , $readTemplate, 'PUT' , encode_json \%message  );

  if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
    return "Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}";
  }
  return $d->{enabled};
}

sub WriteMobilePushNotificationSettings2Tado {

    my $hash = shift;
    my $zoneID = shift;
    my $name = $hash->{NAME};

    my $readTemplate = GetMessageTemplate( $hash, "UpdateMobileDevice", $zoneID );

		my %message ;
		$message{'pushNotifications'}->{'lowBatteryReminder'}  = shift;
		$message{'pushNotifications'}->{'awayModeReminder'}  = shift;
		$message{'pushNotifications'}->{'homeModeReminder'}  = shift;
		$message{'pushNotifications'}->{'energySavingsReportReminder'}  = shift;
		$message{'pushNotifications'}->{'openWindowReminder'}  = shift;
		my $val = shift;
        $message{'pushNotifications'}->{'energySavingsReportReminder'}  = $val if( defined($val) && !($val eq ''));
        $val = shift;
		$message{'pushNotifications'}->{'openWindowReminder'}  = $val if( defined($val) && !($val eq ''));


		my $d = httpSimpleOperationOAuth( $hash , $readTemplate, 'PUT' , encode_json \%message  );

		if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
			return "Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}";
		}
		return $d->{enabled};
}

sub WriteMobileSettings2Tado {
  my ($hash, $zoneID, $code, $setting) = @_;
  my $name = $hash->{NAME};

  my $readTemplate = GetMessageTemplate( $hash, "UpdateMobileDevice", $zoneID );

  my %message ;
  $message{$code} = $setting;

  my $d = httpSimpleOperationOAuth( $hash , $readTemplate, 'PUT' , encode_json \%message  );

  if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
    return "Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}";
  }
  RequestMobileDeviceUpdate($hash);
  return $d->{enabled};
}

sub WriteHiRequest2Tado {

  my ($hash, $zoneID) = @_;
  my $readTemplate = GetMessageTemplate( $hash, "identifyDevice", $zoneID );

  my $d = httpSimpleOperationOAuth( $hash , $readTemplate, 'POST'  );

  if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
    return "Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}";
  }
  return $d->{enabled};
}

sub WritePresenceStatus2Tado{

	 my ($hash, $homeAwayStatus) = @_;
	 my $name = $hash->{NAME};

   my $readTemplate = GetMessageTemplate($hash, "setPresenceStatus" );
		
		my %message ;
		$message{'homePresence'} = $homeAwayStatus;

		my $d = httpSimpleOperationOAuth( $hash , $readTemplate, 'PUT',  encode_json \%message  );

		RequestPresenceUpdate($hash);
		return undef;
}


sub GetMessageTemplate {
  my ($hash, $templateName, $zoneID) = @_;
  my $name = $hash->{NAME};

  my $messageTemplate = $url{$templateName};
  my $homeID = ReadingsVal ($name,"HomeID",undef);

  $messageTemplate =~ s/#HomeID#/$homeID/g;
  $messageTemplate =~ s/#ZoneID#/$zoneID/g;
  $messageTemplate =~ s/#DeviceId#/$zoneID/g;

  return $messageTemplate;
}


sub Encrypt($)
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

sub Decrypt($)
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
    <i>Tado</i> implements an interface to the Tado cloud. The plugin can be used to read and write temperature and settings from or to the Tado cloud. The communication is based on the reengineering of the protocol done by Stephen C. Phillips. See <a href="http://blog.scphillips.com/posts/2017/01/the-tado-api-v2/">his blog</a> for more details. Not all functions are implemented within this FHEM extension. By now the plugin is capable to interact with the so called zones (rooms) and the registered devices. The devices cannot be controlled directly. All interaction - like setting a temperature - must be done via the zone and not the device. This means all configuration like the registration of new devices or the assignment of a device to a room must be done using the Tado app or Tado website directly. Once the configuration is completed this plugin can be used. This device is the 'bridge device' like a HueBridge or a CUL. Per zone or device a dedicated device of type 'TadoDevice' will be created.
    The following features / functionalities are defined by now when using Tado and TadoDevices:
    <ul>
    	<li>Tado Bridge
    	<br><ul>
    		<li>Manages the communication towards the Tado cloud environment and documents the status in several readings like which data was refreshed, when it was rerefershed, etc.</li>
    		<li><b>Overall Presence status</b> Indicates wether at least one mobile device is 'at Home'</li>
    		<li><b>Overall Air Comfort</b> Indicates the air comfort of the whole home.</li>
    	</ul></li>
    	<li>Zone (basically a room)
    	<br><ul>
    		<li><b>Temperature Management:</b> Displays the current temperature, allows to set the desired temperature including the Tado modes which can do this manually or automatically</li>
    		<li><b>Zone Air Comfort</b> Indicates the air comfort of the specific room.</li>
    	</ul></li>
    	<li>Device
    	   <br><ul>
    		<li><b>Connection State:</b> Indicate when the actual device was seen the last time</li>
    		<li><b>Battery Level</b> Indicates the current battery level of the device.</li>
       		<li><b>Find device</b> Output a 'Hi' message on the display to identify the specific device</li>
    	</ul></li>
    	<li>Mobile Device<
    	  <br><ul>
    		<li><b>Device Configration:</b> Displays information about the device type and the current configuration (view only)</li>
    		<li><b>Presence status</b> Indicates if the specific mobile device is Home or Away.</li>
    	</ul></li>
    	<li>Weather
    	  <br><ul>
    		<li>Displays information about the ouside waether and the solar intensity (cloud source, not actually measured).</li>
    	</ul></li>
    </ul>
    <br>
    While previous versions of this plugin were using plain authentication encoding the username and the password directly in the URL this version now uses OAuth2 which does a secure authentication and uses security tokens afterwards. This is a huge security improvement. The implementation is based on code written by Philipp (Psycho160). Thanks for sharing.
    <br>
    <br>
    <a name="Tadodefine"></a>
    <b>Define</b>
    <ul>
        <code>define &lt;name&gt; Tado &lt;username&gt; &lt;password&gt; &lt;interval&gt;</code>
        <br>
        <br> Example: <code>define TadoBridge Tado mail@provider.com somepassword 120</code>
        <br>
        <br> The username and password must match the username and password used on the Tado website. Please be aware that username and password are stored and send as plain text. They are visible in FHEM user interface. It is recommended to create a dedicated user account for the FHEM integration. The Tado extension needs to pull the data from the Tado website. The 'Interval' value defines how often the value is refreshed.
    </ul>
    <br>
    <b>Set</b>
    <br>
    <ul>
        <code>set &lt;name&gt; &lt;option&gt;</code>
        <br>
        <br> The <i>set</i> command just offers very limited options. If can be used to control the refresh mechanism. The plugin only evaluates the command. Any additional information is ignored.
        <br>
        <br> Options:
        <ul>
            <li><i>interval</i>
                <br> Sets how often the values shall be refreshed. This setting overwrites the value set during define.</li>
            <li><i>start</i>
                <br> (Re)starts the automatic refresh. Refresh is autostarted on define but can be stopped using stop command. Using the start command FHEM will start polling again.</li>
            <li><i>stop</i>
                <br> Stops the automatic polling used to refresh all values.</li>
            <li><i>presence</i>
                <br> Sets the presence value for the whole Tado account. You can set the status to HOME or AWAY and depending on the status all devices will chnange their confiration between home and away mode. If you're using the mobile devices and the Tado premium feature using geofencing to determine home and away status you should not use this function.</li>
        </ul>
    </ul>
    <br>
    <a name="Tadoget"></a>
    <b>Get</b>
    <br>
    <ul>
        <code>get &lt;name&gt; &lt;option&gt;</code>
        <br>
        <br> You can <i>get</i> the major information from the Tado cloud.
        <br>
        <br> Options:
        <ul>
            <li><i>home</i>
                <br> Gets the home identifier from Tado cloud. The home identifier is required for all further actions towards the Tado cloud. Currently the FHEM extension only supports a single home. If you have more than one home only the first home is loaded.
                <br/><b>This function is automatically executed once when a new Tado device is defined.</b></li>
            <li><i>zones</i>
                <br> Every zone in the Tado cloud represents a room. This command gets all zones defined for the current home. Per zone a new FHEM device is created. The device can be used to display and overwrite the current temperatures. This command can always be executed to update the list of defined zones. It will not touch any existing zone but add new zones added since last update.
                <br/><b>This function is automatically executed once when a new Tado device is defined.</b></li>
            <li><i>update</i>
                <br/> Updates the values of:
                <br/>
                <ul>
                    <li>All Tado zones</li>
                    <li>The presence status of the whole tado account</li>
                    <li>All mobile devices - if attribute <i>generateMobileDevices</i> is set to true</li>
                    <li>All devices - if attribute <i>generateDevices</i> is set to true</li>
                    <li>The weather device - if attribute <i>generateWeather</i> is set to true</li>
                </ul>
                This command triggers a single update not a continuous refresh of the values.
            </li>
            <li><i>devices</i>
                <br/> Fetches all devices from Tado cloud and creates one TadoDevice instance per fetched device. This command will only be executed if the attribute <i>generateDevices</i> is set to <i>yes</i>. If the attribute is set to <i>no</i> or not existing an error message will be displayed and no communication towards Tado will be done. This command can always be executed to update the list of defined devices. It will not touch existing devices but add new ones. Devices will not be updated automatically as there are no values continuously changing.
            </li>
            <li><i>mobile_devices</i>
                <br/> Fetches all defined mobile devices from Tado cloud and creates one TadoDevice instance per mobile device. This command will only be executed if the attribute <i>generateMobileDevices</i> is set to <i>yes</i>. If the attribute is set to <i>no</i> or not existing an error message will be displayed and no communication towards Tado will be done. This command can always be executed to update the list of defined mobile devices. It will not touch existing devices but add new ones.
            </li>
            <li><i>weather</i>
                <br/> Creates or updates an additional device for the data bridge containing the weather data provided by Tado. This command will only be executed if the attribute <i>generateWeather</i> is set to <i>yes</i>. If the attribute is set to <i>no</i> or not existing an error message will be displayed and no communication towards Tado will be done.
            </li>
        </ul>
    </ul>
    <br>
    <a name="Tadoattr"></a>
    <b>Attributes</b>
    <ul>
        <code>attr &lt;name&gt; &lt;attribute&gt; &lt;value&gt;</code>
        <br>
        <br> You can change the behaviour of the Tado Device.
        <br>
        <br> Attributes:
        <ul>
            <li><i>generateDevices</i>
                <br> By default the devices are not fetched and displayed in FHEM as they don't offer much functionality. The functionality is handled by the zones not by the devices. But the devices offers an identification function <i>sayHi</i> to show a message on the specific display. If this function is required the Devices can be generated. Therefor the attribute <i>generateDevices</i> must be set to <i>yes</i>
                <br/><b>If this attribute is set to <i>no</i> or if the attribute is not existing no devices will be generated..</b>
            </li>
            <li><i>generateMobileDevices</i>
                <br> By default the mobile devices are not fetched and displayed in FHEM as most users already have a person home recognition. If Tado shall be used to identify if a mobile device is at home this can be done using the mobile devices. In this case the mobile devices can be generated. Therefor the attribute <i>generateMobileDevices</i> must be set to <i>yes</i>
                <br/><b>If this attribute is set to <i>no</i> or if the attribute is not existing no mobile devices will be generated..</b>
            </li>
            <li><i>generateWeather</i>
                <br> By default no weather channel is generated. If you want to use the weather as it is defined by the tado system for your specific environment you must set this attribute. If the attribute <i>generateWeather</i> is set to <i>yes</i> an additional weather channel can be generated.
                <br/><b>If this attribute is set to <i>no</i> or if the attribute is not existing no Devices will be generated..</b>
            </li>
        </ul>
 </ul>
    <br>
    <a name="Tadoreadings"></a>
    <b>Generated Readings/Events:</b>
		<br>
    <ul>
        <ul>
            <li><b>DeviceCount</b>
                <br> Indicates how many devices (hardware devices provided by Tado) are registered in the linked Tado Account.
                <br/> This reading will only be available / updated if the attribute <i>generateDevices</i> is set to <i>yes</i>.
            </li>
            <li><b>LastUpdate_Devices</b>
                <br> Indicates when the last successful request to update the hardware devices (TadoDevices) was send to the Tado API. his reading will only be available / updated if the attribute <i>generateDevices</i> is set to <i>yes</i>.
            </li>
            <li><b>HomeID</b>
                <br> Unique identifier for your Tado account instance. All devices are linked to your homeID and the homeID required for almost all Tado API requests.
            </li>
            <li><b>HomeName</b>
                <br> Name of your Tado home as you have configured it in your Tado account.
            </li>
            <li><b>Presence</b>
                <br> The current presence status of your home. The status can be HOME or AWAY and is valid for the whole home and all devices and zones linked to this home. The Presence reading can be influences by the <i>set presence</i> command or based on geofencing using mobile devices.
            </li>
            <li><b>airComfort_freshness</b>
                <br> The overall fresh air indicator for your home. Represents a summary of the single indicators per zone / room.
            </li>
            <li><b>airComfort_lastWindowOpen</b>
                <br> Inidcates the last time an open window was detected by Tado to refresh the air within the home.
            </li>
            <li><b>LastUpdate_AirComfort</b>
                <br> Indicates when the last successful request to update the air comfort was send to the Tado API.
            </li>
            <li><b>LastUpdate_MobileDevices</b>
                <br> Indicates when the last successful request to update the mobile devices was send to the Tado API. his reading will only be available / updated if the attribute <i>generateMobileDevices</i> is set to <i>yes</i>.
            </li>
            <li><b>LastUpdate_Weather</b>
                <br> Indicates when the last successful request to update the weather was send to the Tado API. his reading will only be available / updated if the attribute <i>generateWeather</i> is set to <i>yes</i>.
            </li>
            <li><b>LastUpdate_Zones</b>
                <br> Indicates when the last successful request to update the zone / room data was send to the Tado API.
            </li>
        </ul>
    </ul>
</ul>

=end html

=cut
