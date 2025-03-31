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
		readingsDelete
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
		setKeyValue
		getKeyValue)
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
);

my %sets = (
start	=> " ",
stop => " ",
interval => " ",
presence => " ",
authenticate => " ",
);

my %homeAwayStatus = (
HOME	=> " ",
AWAY => " ",
);


my  %url = (
startOAuthDeviceAuth   => 'https://login.tado.com/oauth2/device_authorize',
getOAuthToken          => 'https://login.tado.com/oauth2/token',
);

my %dpoints = (
    getZoneTemperature => {
        url      => 'homes/#HomeID#/zones/#ZoneID#/state',
    },
    setZoneTemperature => {
        url      => 'homes/#HomeID#/zones/#ZoneID#/overlay',
    },
    getEarlyStart => {
        url      => 'homes/#HomeID#/zones/#ZoneID#/earlyStart',
    },
    setEarlyStart => {
        url      => 'homes/#HomeID#/zones/#ZoneID#/earlyStart',
    },	
    getZones => {
        url      => 'homes/#HomeID#/zones',
    },
    getHomeId => {
        url      => 'me',
    },
    getMobileDevices => {
        url      => 'homes/#HomeID#/mobileDevices',
        attribute => 'generateMobileDevices',
    },
    UpdateMobileDevice => {
        url      => 'homes/#HomeID#/mobileDevices/#DeviceId#/settings',
        attribute => 'generateMobileDevices',
    },
    getHomeDetails => {
        url      => 'homes/#HomeID#',
    },
    getWeather => {
        url      => 'homes/#HomeID#/weather',
        attribute => 'generateWeather',
    },
    getDevices => {
        url      => 'homes/#HomeID#/devices',
        attribute => 'generateDevices',
    },
    identifyDevice => {
        url      => 'devices/#DeviceId#/identify',
        attribute => 'generateDevices',
    },
    getAirComfort => {
        url      => 'homes/#HomeID#/airComfort',
    },
    setPresenceStatus => {
        url      => 'homes/#HomeID#/presenceLock',
    },
    getPresenceStatus => {
        url      => 'homes/#HomeID#/state',
    },
);


my %oauth = (
client_id     => '1bb50063-6b0c-4d11-bd99-387f4a91cc46',
scope         => 'offline_access',
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
	. 'generateMobileDevices:yes,no '
	. 'generateWeather:yes,no '
	. $readingFnAttributes;

	Log 3, "Tado module initialized.";
	return;
}

sub Setup{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	RemoveInternalTimer($hash);

	#Initial load of the homes
	if(CanAuthenticate2Tado($hash)){
		readingsSingleUpdate($hash, 'state', 'initializing', 0);
		WriteToCloudAPI( $hash, 'getHomeId', 'GET', undef);		
		#Call getZones with delay of 15 seconds, as all devices need to be loaded before timer triggers.
		#Otherwise some error messages are generated due to auto created devices...
		InternalTimer(gettimeofday()+15, "FHEM::Tado::GetZones", $hash) if (defined $hash);		
		Log3 $name, 1, sprintf("Define %s: Starting timer with interval %s", $name, InternalVal($name,'INTERVAL', undef));
		InternalTimer(gettimeofday()+ InternalVal($name,'INTERVAL', undef), "FHEM::Tado::UpdateDueToTimer", $hash) if (defined $hash);	
		return undef;		
	} else {
		my $message = "[Error] No valid token found. Please authenticate first.";
		_logError($hash, $message);	
		readingsSingleUpdate($hash, 'state', $message, 0);
	}
}


sub Define($$)
{
	my ($hash, $def) = @_;
	my @param = split("[ \t]+", $def);
	my $name = $hash->{NAME};
	my $errmsg = '';

	Log3 $name, 3, "Define $name: called ";

	# Check parameter(s) - Must be min 2 in total (counts strings not purly parameter, interval is optional)
	if( int(@param) < 2 ) {
		$errmsg = return "syntax error: define <name> Tado [Interval]";
		Log3 $name, 1, "Tado $name: " . $errmsg;
		return $errmsg;
	}

	# Handle old definition before auth refactoring'
	delete $hash->{Password};
	if (int(@param) >= 4 && int(@param) <= 5) {
		$errmsg = "Modul was defined before auth refactoring. Please remove user and password from definition.";
		Log3 $name, 1, "Tado $name: " . $errmsg;
		if(int(@param) == 5) {
			$param[2] = $param[5];
		} else {
			$param[2] = 60;
		}
	}

	$hash->{APIURI} = 'https://my.tado.com/api/v2/';

	if (defined $param[2]) {
		$hash->{DEF} = sprintf("%s", $param[2]);
	} 

	#Check if interval is set and numeric.
	#If not set -> set to 60 seconds
	#If less then 5 seconds set to 5
	#If not an integer abort with failure.
	my $interval = 60;
	if (defined $param[2]) {
		if ( $param[2] =~ /^\d+$/ ) {
			$interval = $param[2];
		} else {
			$errmsg = "Specify valid integer value for interval. Whole numbers > 5 only. Format: define <name> Tado [interval]";
			Log3 $name, 1, "Tado $name: " . $errmsg;
			return $errmsg;
		}
	}

	if( $interval < 5 ) { $interval = 5; }
	$hash->{INTERVAL} = $interval;

	readingsSingleUpdate($hash,'state','preparing',0);

	GenerateAttribute($name,"generateDevices","no");
	GenerateAttribute($name,"generateMobileDevices","no");
	GenerateAttribute($name,"generateWeather","no");

	Setup($hash);
	return undef
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


sub _logError
{
	my $hash = shift;
	my $name = $hash->{NAME};
	my $err  = shift;

	if (defined $err) {
		Log3 $name, 1, "Error in device '$name': $err";
		readingsSingleUpdate($hash, "last_error", $err, 1 );
	}
	else {
		Log3 $name, 1, "Unknown error in device '$name'.";
		readingsSingleUpdate($hash, "last_error", "Unknown error", 1 );
	}
}

sub _loadToken 
{
    my $hash          = shift;
    my $name          = $hash->{NAME};
    my $tokenLifeTime = $hash->{TOKEN_LIFETIME}; 
	my $Token = $hash->{'.TOKEN'};

	$tokenLifeTime = 0 if (!defined $tokenLifeTime || $tokenLifeTime eq '' || $tokenLifeTime !~ /^\d+$/);

	# Error while loading
	if ($@) {
		return ("Error while loading token: $@. Please authenticate again.", undef);
	}

	# Token exists & is Valid for more than 90 seconds
	if ( defined $Token && defined $Token->{'access_token'}  && $tokenLifeTime > gettimeofday() + 90 ) {
		return (undef, $Token);
	}

	# Token almost expired or expired - refresh it
	else {
		Log3 $name, 5, "Tado $name" . ": " . "Token is expiring or expired, requesting new one";
		return _refreshToken($hash);
	}
}

sub _refreshToken 
{
    my $hash          = shift;
    my $name          = $hash->{NAME};

    my $Token         = undef;
	my $err;
	my $returnData;
	my $refreshToken;
    # load token
    $Token = $hash->{'.TOKEN'};


	# No token loaded, get from persistent storage
	if ( !defined $Token ) {
		Log3 $name, 1, "Tado $name" . ": No token loaded. Getting latest refresh token from storage.";
		($err, $refreshToken) = getKeyValue($name."_RefreshToken");

		if ($err || !defined $refreshToken || $refreshToken eq '') {
			my $errMsg = "No Token or Refresh Token available. Please authenticate again.";
			Log3 $name, 1, "Tado $name" . ": $errMsg";
			return ($errMsg, undef);
		}

	} else {
		$refreshToken = $Token->{'refresh_token'};
	}

    my $data = {
        client_id     => $oauth{client_id},
        grant_type    => 'refresh_token',
        refresh_token => $refreshToken
    };

    my $param = {
        url     => $url{getOAuthToken},
        method  => 'POST',
        timeout => 5,
        hash    => $hash,
        data    => $data
    };

    ( $err, $returnData ) = HttpUtils_BlockingGet($param);

	# Request Error
    if ( $err ne "" ) {
		my $errMsg = "TokenRefresh: Error in token retrival while requesting ". $param->{url}. " - $err";
        Log3 $name, 3, "Tado $name" . ": $errMsg";
		return ($errMsg, undef);
    }

    elsif ( $returnData ne "" ) {
        Log3 $name, 5, "url " . $param->{url} . " returned: $returnData";
        my $decoded_data = eval { decode_json($returnData); };

		# JSON decode error
        if ($@) {
			my $errMsg = "TokenRefresh: decode_json failed, invalid json. error: $@";
			Log3 $name, 3, "Tado $name" . ": $errMsg";
			return ($errMsg, undef);
        }
        else {
            #write token data in file
			 if (defined($decoded_data)){
				$hash->{'.TOKEN'} = $decoded_data;
				setKeyValue($name."_RefreshToken", $decoded_data->{'refresh_token'}) if length($decoded_data->{'refresh_token'}) > 10;
				Log3 $name, 4, "Tado Updated persistent refresh token:" . $decoded_data->{'refresh_token'};
			 }


            # token lifetime management
            $hash->{TOKEN_LIFETIME} = gettimeofday() + $decoded_data->{'expires_in'};
            $hash->{TOKEN_LIFETIME_HR} = localtime( $hash->{TOKEN_LIFETIME} );
            Log3 $name, 5, "Tado $name" . ": TokenRefresh: Refreshed authentication token successfully. Valid until ". localtime( $hash->{TOKEN_LIFETIME} );
			return (undef, $decoded_data);
        }
    }

	else {	
    	return ("Received empty response from Tado API", undef);
	}



}


sub RegisterOAuthDevice {
    my $hash          = shift;
    my $name          = $hash->{NAME};

	my $data = {
        client_id     => $oauth{client_id},
        scope         => $oauth{scope},
    };

    my $param = {
        url     => $url{startOAuthDeviceAuth},
        method  => 'POST',
        timeout => 5,
        hash    => $hash,
        data    => $data
    };

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

		$hash->{AUTH_DEVICE_CODE} = $decoded_data->{'device_code'};
		$hash->{AUTH_INTERVAL} = $decoded_data->{'interval'};

		my $url = $decoded_data->{'verification_uri_complete'};

		readingsSingleUpdate($hash,'device_auth_url',"$url",1);
        readingsSingleUpdate($hash,'state',"Please continue in browser: $url",1);

		InternalTimer(gettimeofday()+ $hash->{AUTH_INTERVAL}, "FHEM::Tado::UpdateAuthTimer", $hash);

	}
	
}

sub UpdateAuthTimer($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	my $data = {
        client_id     => $oauth{client_id},
		device_code   => $hash->{AUTH_DEVICE_CODE},
        grant_type    => "urn:ietf:params:oauth:grant-type:device_code"
    };

    my $param = {
        url     => $url{getOAuthToken},
        method  => 'POST',
        timeout => 5,
        hash    => $hash,
        data    => $data
    };

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


		if (defined($decoded_data) && defined($decoded_data->{'access_token'})) {
            $hash->{'.TOKEN'} = $decoded_data;
			setKeyValue($name."_RefreshToken", $decoded_data->{'refresh_token'}) if length($decoded_data->{'refresh_token'}) > 10;
			$hash->{TOKEN_LIFETIME} = gettimeofday() + $decoded_data->{'expires_in'};
			$hash->{TOKEN_LIFETIME_HR} = localtime( $hash->{TOKEN_LIFETIME} );
			Log3 $name, 5,
				"Tado $name" . ": "
				. "Retrived new authentication token successfully. Valid until "
				. localtime( $hash->{TOKEN_LIFETIME} );		
			readingsSingleUpdate($hash,'state','authenticated',0);


			readingsDelete ($hash, "device_auth_url");
			delete $hash->{AUTH_DEVICE_CODE};
			delete $hash->{AUTH_INTERVAL};


			RemoveInternalTimer($hash);
			Setup($hash);
			readingsSingleUpdate($hash,'state','polling',0);

			return $decoded_data;
		}

	}

	#local allows call of function without adding new timer.
	#must be set before call ($hash->{LOCAL} = 1) and removed after (delete $hash->{LOCAL};)
	#You just get here if the call did not sucessfully return data Then you need to loop the auth timer.
	if(!$hash->{LOCAL}) {
		RemoveInternalTimer($hash);
		InternalTimer(gettimeofday()+ $hash->{AUTH_INTERVAL}, "FHEM::Tado::UpdateAuthTimer", $hash);
		readingsSingleUpdate($hash,'state','polling authentication',0);
	}

}

sub CanAuthenticate2Tado {
	my $hash          = shift;
	my $name          = $hash->{NAME};

    # load token
	my $Token = $hash->{'.TOKEN'};

	if ( defined $Token && defined $Token->{'access_token'} && defined $Token->{'refresh_token'} && $hash->{TOKEN_LIFETIME} > gettimeofday() - 60 * 60 * 24 * 30 ) {
		return 1;
	}
	else 
	{
		my ($err, $refreshToken) = getKeyValue($name."_RefreshToken");
		if (defined $refreshToken) {
			$Token = $hash->{'.TOKEN'}->{'refresh_token'} = $refreshToken;
			return 1;
		}	
		return 0;
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

		return WriteToCloudAPI( $hash, 'getHomeId', 'GET' );

	} elsif($opt eq "zones") {

		return WriteToCloudAPI( $hash, 'getZones', 'GET', undef);	

	}  elsif($opt eq "update")  {

		Log3 $name, 3, "Get $name: Updating readings for all zones";
		$hash->{LOCAL} = 1;
		GetZoneTemperatures($hash);
		WriteToCloudAPI( $hash, 'getWeather', 'GET', undef);
		WriteToCloudAPI( $hash, 'getMobileDevices', 'GET', undef);
		WriteToCloudAPI( $hash, 'getAirComfort', 'GET', undef);
		WriteToCloudAPI( $hash, 'getDevices', 'GET', undef);
		WriteToCloudAPI( $hash, 'getPresenceStatus', 'GET', undef);

		delete $hash->{LOCAL};
		return undef;

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
		return "Unknown argument $opt, choose one of authenticate start stop interval presence:HOME,AWAY";
	}

	if ($opt eq "authenticate")	{
 		Log3 $name, 3, "Tado: set $name: processing ($opt)";
         RegisterOAuthDevice($hash);
         Log3 $name, 3, "Tado $name" . ": " . "$opt finished\n";
		 return undef;
	}

	if ($opt eq "start")	{
		RemoveInternalTimer($hash);

		$hash->{LOCAL} = 1;
		GetZoneTemperatures($hash);
		delete $hash->{LOCAL};

		InternalTimer(gettimeofday()+ InternalVal($name,'INTERVAL', undef), "FHEM::Tado::UpdateDueToTimer", $hash);
		Log3 $name, 1, sprintf("Set %s: Updated readings and started timer to automatically update readings with interval %s", $name, InternalVal($name,'INTERVAL', undef));
		
		readingsSingleUpdate($hash,'state','polling',0);
		return undef;
	}    

	if ($opt eq "stop"){

		RemoveInternalTimer($hash);
		Log3 $name, 1, "Set $name: Stopped the timer to automatically update readings";
		readingsSingleUpdate($hash,'state','initialized',0);
		return undef;

	} 
	
	if ($opt eq "interval"){

		my $interval = shift @param;
		$interval= 60 unless defined($interval);
		if( $interval < 5 ) { $interval = 5; }
		Log3 $name, 1, "Set $name: Set interval to" . $interval;
		$hash->{INTERVAL} = $interval;
		return undef;

	} 
	
	if ($opt eq "presence"){
    	my $status = shift @param;

		if(!$homeAwayStatus{$status}) {
			my @pList = keys %homeAwayStatus;
			my $errMsg = "Unknown argument $status, choose one of presence:HOME,AWAY";
			_logError($hash, $errMsg);
			return $errMsg;
		}

		my %message ;
		$message{'homePresence'} = $status;

		WriteToCloudAPI( $hash, 'setPresenceStatus', 'PUT',  \%message );
		return undef;
	}

	_logError($hash, "Unknown Set-Command: $opt");
	return "Unknown Set-Command: $opt";
}

sub Attr(@)
{
	return undef;
}



#This function is called by the timer to update the readings after creation.
sub GetZones($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	WriteToCloudAPI( $hash, 'getZones', 'GET', undef);		
	return undef;
}

sub GetZoneTemperatures
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	foreach my $zone (split /, /,  InternalVal($name,'ZoneIDs', undef)) {
		WriteToCloudAPI( $hash, 'getZoneTemperature', 'GET', undef, $zone);
	}
}

sub WriteTemperature2Tado 
{
    my ($hash, $zoneID, $duration, $temperature) = @_;
    my $name = $hash->{NAME};

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
		WriteToCloudAPI( $hash, 'setZoneTemperature', 'DELETE', undef, $zoneID);
		return undef;
	} else {
		$message{'termination'}{'type'}  = 'TIMER';
		$message{'termination'}{'durationInSeconds'} = $duration * 60;
	}

	WriteToCloudAPI( $hash, 'setZoneTemperature', 'PUT', \%message, $zoneID);
	return undef;
}

sub CanExecuteCloudAPICommand 
{
    my ($hash, $dpoint) = @_;
    my $name = $hash->{NAME};

    if (exists $dpoints{$dpoint}) {
        my $attribute = $dpoints{$dpoint}->{attribute};
        if (defined $attribute) {
            my $isEnabled = AttrVal($name, $attribute, 'yes');
            if ($isEnabled eq 'no') {
                my $msg = "Attribute '$attribute' is set to 'no'. Command for '$dpoint' will not be executed.";
                Log3 $name, 4, $msg;
                return (0, $msg);
            }
        }
    }

    # Executable if no attribute is defined or attribute is set to 'yes'
    return (1, undef);
}

sub WriteToCloudAPI 
{
	my ($hash, $dpoint, $method, $message, $extraId) = @_;
    my $name = $hash->{NAME};
    my $url  = $hash->{APIURI} . $dpoints{$dpoint}->{url};
    my $payload;

    $payload = encode_json \%$message if defined $message;

    if ( not defined $hash ) {
        my $msg =
          "Error on Tado_WriteToCloudAPI. Missing hash variable";
        Log3 'Tado', 1, $msg;
        return $msg;
    }

    my ($canExecute, $msg) = CanExecuteCloudAPICommand($hash, $dpoint);
    return $msg unless $canExecute;


    #Check if HomeID is required in URL and replace or alert.
    if ( $url =~ m/\#HomeID\#/x )
    {
        my $homeID = ReadingsVal ($name,"HomeID",undef);
        if ( not defined $homeID ) {
            my $error =	"Error on Tado_WriteToCloudAPI. Missing HomeID. Please define Home first. Endpoint: $dpoint";
            Log3 $name, 1, $error;
            return $error;
        }
        $url =~ s/#HomeID#/$homeID/g;
    }


    #Check if ZoneID is required in URL and replace or alert.
    if ( $url =~ m/\#ZoneID\#/x )
    {
        if ( not defined $extraId ) {
            my $error =	"Error on Tado_WriteToCloudAPI. Missing ZoneID in call. Either zones are not defined or this is a coding fault.";
            Log3 $name, 1, $error;
            return $error;
        }
        $url =~ s/#ZoneID#/$extraId/g;
    }

    #Check if DeviceId is required in URL and replace or alert.
    if ( $url =~ m/\#DeviceID\#/x )
    {
        if ( not defined $extraId ) {
            my $error =	"Error on Tado_WriteToCloudAPI. Missing DeviceID in call. Either zones are not defined or this is a coding fault.";
            Log3 $name, 1, $error;
            return $error;
        }
        $url =~ s/#DeviceID#/$extraId/g;
    }

    my ($err, $CurrentTokenData) = _loadToken($hash);

	if ($err) {
		_logError($hash, $err);		
		readingsSingleUpdate($hash, 'state', "[Error]: $err", 1 );
		return undef;
	}

    my $header           = {
        "Content-Type" => "application/json;charset=UTF-8",
        "Authorization" =>
          "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
    };

    HttpUtils_NonblockingGet(
        {
            url                => $url,
            timeout            => 15,
            incrementalTimeout => 1,
            hash               => $hash,
            dpoint             => $dpoint,
			extra_id		   => $extraId,
            data               => $payload,
            method             => $method,
            header             => $header,
            callback           => \&ResponseHandling
        }
    );
    return;

}

sub ResponseHandling 
{
    my $param = shift;
    my $err   = shift;
    my $data  = shift;
    my $hash  = $param->{hash};
    my $name  = $hash->{NAME};
    my $decoded_json;
    my $value;

    Log3 $name, 4, "Callback received. " . $param->{url};
	Log3 $name, 4, "FHEM -> Tado: " . $param->{message} if (defined $param->{message});
	Log3 $name, 4, "Tado -> FHEM: " . $data;

	#function call error
	if ( $err ne "" ) {
        Log3 $name, 1, "error while requesting ". $param->{url}. " - $err";
		_logError($hash, $err);
        return undef;
    }

	eval { $decoded_json = decode_json($data) }; 

	#message content error
	if (defined $decoded_json && ref($decoded_json) eq "HASH" && defined $decoded_json->{errors}){
		_logError($hash, "$decoded_json->{errors}[0]->{code} / $decoded_json->{errors}[0]->{title}");
		log 1, Dumper $decoded_json;
		readingsSingleUpdate($hash,'state',"[Error]: $decoded_json->{errors}[0]->{code} / $decoded_json->{errors}[0]->{title}" , 1);
		return undef;
	}	

	if ($param->{dpoint} eq 'getHomeId'){
		
		my $saveDeviceName = makeDeviceName($decoded_json->{homes}[0]->{name});
		readingsSingleUpdate($hash, "HomeID", $decoded_json->{homes}[0]->{id}, 1);
		readingsSingleUpdate($hash, "HomeName", $saveDeviceName, 1 );

		Log3 $name, 1, "Defined / Updated HomeId for device '$name'. Id: $decoded_json->{homes}[0]->{id} Name: $saveDeviceName";

		# This code should not be called, as TADO states in the FAQ they're currently just supporting one single home.
		if (scalar (@{$decoded_json->{homes}}) > 1 ){
			$saveDeviceName = makeDeviceName($decoded_json->{homes}[1]->{name});
			readingsSingleUpdate($hash, "HomeID_2", $decoded_json->{homes}[1]->{id}, 1 );
			readingsSingleUpdate($hash, "HomeName_2",  $saveDeviceName, 1);

			Log3 $name, 1, "Attention!! Additional HomeId defined for device '$name'. This is officially not supported by Tado. Id: $decoded_json->{homes}[1]->{id} Name: $saveDeviceName";
		}
		return undef;
	}

	if ( $param->{dpoint} eq 'getZoneTemperature' ) {
		Processing_Dpoint_GetZoneTemperature( $hash, $decoded_json, $param->{extra_id} );
		return undef;
	}

	if ( $param->{dpoint} eq 'getZones'){
		Processing_Dpoint_GetZones( $hash, $decoded_json );
		return undef;
	}


	if ( $param->{dpoint} eq 'getEarlyStart' ) {
		my $message = "Tado;$param->{extra_id};earlyStart;$decoded_json->{enabled}";

		_dispatchMessage($hash, $message);
		return undef;
	}

	if ($param->{dpoint} eq 'getWeather') {

		_autocreateWeatherChannel($hash, $decoded_json);

		my $message = "Tado;weather;weather;"
		. $decoded_json->{solarIntensity}->{percentage} . ";"
		. $decoded_json->{solarIntensity}->{timestamp} . ";"
		. $decoded_json->{outsideTemperature}->{celsius} . ";"
		. $decoded_json->{outsideTemperature}->{timestamp} . ";"
		. $decoded_json->{weatherState}->{value} . ";"
		. $decoded_json->{weatherState}->{timestamp};

		_dispatchMessage($hash, $message);

		readingsSingleUpdate($hash, "LastUpdate_Weather", localtime, 1 );
		return undef;
	}

	if ($param->{dpoint} eq 'getDevices') {
		
		for my $item( @{$decoded_json} ){

			_autocreateDevice($hash, $item);

      		my $deviceId = "$item->{serialNo}";
			my $message = "Tado;$deviceId;devicedata;";

			$message .= join(";",
				_getValue($item, '{currentFwVersion}'),
				_getValue($item, '{inPairingMode}'),
				_getValue($item, '{batteryState}'),
				_getValue($item, '{connectionState}->{value}'),
				_getValue($item, '{connectionState}->{timestamp}'),
			). ";";

			_dispatchMessage($hash, $message);
		}

		readingsSingleUpdate ($hash, "LastUpdate_Devices", localtime, 1 );
		return undef;
	}

	if ($param->{dpoint} eq 'getMobileDevices'){
		Processing_Dpoint_GetMobileDevices($hash, $decoded_json);
		return undef;
	}

	if ($param->{dpoint} eq 'getPresenceStatus'){
		readingsSingleUpdate($hash, "Presence", $decoded_json->{presence}, 1);
		return undef;
	}

	if ($param->{dpoint} eq 'getAirComfort'){

		readingsSingleUpdate($hash, "airComfort_freshness", $decoded_json->{freshness}->{value}, 1 );
		readingsSingleUpdate($hash, "airComfort_lastWindowOpen", $decoded_json->{freshness}->{lastOpenWindow}, 1 );

		foreach my $values (@{$decoded_json->{comfort}})
		{
     		Log3 $name, 4, "Trying to decode message: ". Dumper($values);
			my $message = "Tado;$values->{roomId};airComfort;";


		 	$message .= $values->{temperatureLevel} . ";"
					. $values->{humidityLevel} . ";"
					. $values->{coordinate}->{radial} . ";"
					. $values->{coordinate}->{angular} . ";";

			_dispatchMessage($hash, $message);
		}

		readingsSingleUpdate($hash, "LastUpdate_AirComfort", localtime, 1 );
		return undef;
	}

	if ($param->{dpoint} eq 'setPresenceStatus'){
		WriteToCloudAPI( $hash, 'getPresenceStatus', 'GET', undef);
		return undef;
	}

	if ($param->{dpoint} eq 'setZoneTemperature'){
		GetZoneTemperatures($hash);
		return undef;
	}

	if ($param->{dpoint} eq 'setEarlyStart'){
		WriteToCloudAPI( $hash, 'getEarlyStart', 'GET', undef, $param->{extra_id});
		return undef;
	}

	if ($param->{dpoint} eq 'UpdateMobileDevice'){
		GetMobileDevices($hash);
		return undef;
	}

	if ($param->{dpoint} eq 'identifyDevice'){
		#do nothing
		return undef;
	}

	Log3 $name, 1, "Unknown dpoint: $param->{dpoint}";

}

sub _dispatchMessage 
{
	my $hash    = shift;
	my $message = shift;
	my $name    = $hash->{NAME};

	Log3 $name, 4, "Trying to dispatch message: $message";
	my $found = Dispatch($hash, $message);
	Log3 $name, 4, "Tried to dispatch message. Result: $found";
	return $found;
}

sub _getValue 
{
	my ($base, $path) = @_;
	my $val = eval "\$base->$path";
	return defined $val ? $val : "";
}

sub Processing_Dpoint_GetZoneTemperature 
{
    my $hash         = shift;
    my $decode_json = shift;
	my $zoneID = shift;
    my $name = $hash->{NAME};

    Log3 $name, 5, 'Evaluating GetZoneTemperature';

	my $message = "Tado;$zoneID;temp;";

	#measured-temp-*
	$message .= join(";",
			_getValue($decode_json, '{sensorDataPoints}->{insideTemperature}->{celsius}'),
			_getValue($decode_json, '{sensorDataPoints}->{insideTemperature}->{timestamp}'),
			_getValue($decode_json, '{sensorDataPoints}->{insideTemperature}->{fahrenheit}'),
			_getValue($decode_json, '{sensorDataPoints}->{insideTemperature}->{precision}->{celsius}'),
			_getValue($decode_json, '{sensorDataPoints}->{insideTemperature}->{precision}->{fahrenheit}'),
		). ";";


	# desired temperature or OFF
	$message .= $decode_json->{setting}->{power} eq "OFF"
		? "OFF;"
		: _getValue($decode_json, '{setting}->{temperature}->{celsius}') . ";";


	$message .= join(";",
		_getValue($decode_json, '{sensorDataPoints}->{humidity}->{percentage}'),
		_getValue($decode_json, '{sensorDataPoints}->{humidity}->{timestamp}'),
		_getValue($decode_json, '{link}->{state}'),
		defined $decode_json->{openWindow} ? "true" : "null",
		defined $decode_json->{openWindowDetected} ? $decode_json->{openWindowDetected} : "false",
		_getValue($decode_json, '{activityDataPoints}->{heatingPower}->{percentage}'),
		_getValue($decode_json, '{activityDataPoints}->{heatingPower}->{timestamp}')
	) . ";";

	if (defined $decode_json->{nextScheduleChange}) {
		$message .= join(";", 
			_getValue($decode_json, '{nextScheduleChange}->{setting}->{temperature}->{celsius}'),
			_getValue($decode_json, '{nextScheduleChange}->{setting}->{power}'),
			_getValue($decode_json, '{nextScheduleChange}->{start}')
		) . ";";
	} else {
		$message .= ";;;";
	}	

	$message .= (defined $decode_json->{tadoMode} ? $decode_json->{tadoMode} : "null") . ";";

	my $overlay = defined $decode_json->{overlay} ? 1 : 0;
	$message .= "$overlay;";

	if ($overlay) {
		$message .= join(";", 
			$decode_json->{overlay}->{type},
			$decode_json->{overlay}->{setting}->{power},
			($decode_json->{overlay}->{setting}->{power} ne 'OFF' 
				? $decode_json->{overlay}->{setting}->{temperature}->{celsius} 
				: 'OFF'),
			$decode_json->{overlay}->{termination}->{type}
		) . ";";

		if ($decode_json->{overlay}->{termination}->{type} ne 'MANUAL') {
			$message .= join(";", 
				_getValue($decode_json, '{overlay}->{termination}->{durationInSeconds}'),
				_getValue($decode_json, '{overlay}->{termination}->{expiry}'),
				_getValue($decode_json, '{overlay}->{termination}->{remainingTimeInSeconds}')
			) . ";";
		} else {
			$message .= ";;;";
		}
	} else {
		$message .= ";;;;;;;";
	}

	if (defined $decode_json->{openWindow}) {
		$message .= join(";", 
			_getValue($decode_json, '{openWindow}->{detectedTime}'),
			_getValue($decode_json, '{openWindow}->{durationInSeconds}'),
			_getValue($decode_json, '{openWindow}->{expiry}')
		) . ";";
	} else {
		$message .= ";;;";
	}

	_dispatchMessage($hash, $message);

	readingsSingleUpdate($hash, "LastUpdate_Zones", localtime, 1);
	return undef;
}

sub Processing_Dpoint_GetMobileDevices 
{
    my $hash         = shift;
    my $d 			 = shift;
    my $name         = $hash->{NAME};

    Log3 $name, 5, 'Evaluating GetMobileDevices';

	my %MobileDeviceIds = ();
	my $count = 0;

	for my $item (@{$d}) {

		_autocreateMobileDevice($hash, $item);
		$MobileDeviceIds{$item->{id}} = $item->{name};

		my $message = "Tado;$item->{id};locationdata;" 
			. $item->{settings}->{geoTrackingEnabled} . ";";

		if ($item->{settings}->{geoTrackingEnabled}) {
			$message .= join(";", 
				_getValue($item,'{location}->{stale}'),
				_getValue($item,'{location}->{atHome}'),
				_getValue($item,'{location}->{bearingFromHome}->{degrees}'),
				_getValue($item,'{location}->{bearingFromHome}->{radians}'),
				_getValue($item,'{location}->{relativeDistanceFromHomeFence}')
			) . ";";
		} else {
			$message .= ";;;;;";
		}

		if (defined $item->{settings}->{pushNotifications}) {
			$message .= join(";", 
				_getValue($item,'{settings}->{pushNotifications}->{lowBatteryReminder}'),
				_getValue($item,'{settings}->{pushNotifications}->{awayModeReminder}'),
				_getValue($item,'{settings}->{pushNotifications}->{homeModeReminder}'),
				_getValue($item,'{settings}->{pushNotifications}->{openWindowReminder}'),
				_getValue($item,'{settings}->{pushNotifications}->{energySavingsReportReminder}'),
				_getValue($item,'{settings}->{pushNotifications}->{incidentDetection}'),
				_getValue($item,'{settings}->{pushNotifications}->{energyIqReminder}')
			) . ";";
		} else {
			$message .= ";;;;;;;";
		}

		if (defined $item->{deviceMetadata}) {
			$message .= join(";", 
				_getValue($item,'{deviceMetadata}->{platform}'),
				_getValue($item,'{deviceMetadata}->{osVersion}'),
				_getValue($item,'{deviceMetadata}->{model}'),
				_getValue($item,'{deviceMetadata}->{locale}')
			) . ";";
		} else {
			$message .= ";;;;";
		}

		$message .= join(";", 
			_getValue($item,'{settings}->{specialOffersEnabled}'),
			_getValue($item,'{settings}->{onDemandLogRetrievalEnabled}')
		) . ";";

		_dispatchMessage($hash, $message);
	}

	$hash->{MobileDeviceIDs} = join(", ", keys %MobileDeviceIds);
	readingsSingleUpdate($hash, "LastUpdate_MobileDevices", localtime, 1 );
	return undef;
}

sub _autocreateDevice
{
    my $hash         = shift;
    my $item 		 = shift;
    my $name         = $hash->{NAME};

    Log3 $name, 5, 'Autocreating Tado Devices if not existing';

	my $code = $name ."-". $item->{serialNo};

	if( defined($modules{TadoDevice}{defptr}{$code}) )
	{
		Log3 $name, 4, "GetDevices ($name): device id '$item->{serialNo}' already defined as '$modules{TadoDevice}{defptr}{$code}->{NAME}'";

	} else {

		my $deviceName = "Tado_" . $item->{serialNo};
		$deviceName =~ s/ /_/g;
		my $define= "$deviceName TadoDevice $item->{serialNo} IODev=$name";

		Log3 $name, 1, "GetDevices ($name): created new device '$deviceName' of type '$item->{deviceType}'";

		my $cmdret= CommandDefine(undef,$define);

		if(defined $cmdret) {
			if( not index($cmdret, 'already defined') != -1) {
				Log3 $name, 1, "$name: Autocreate: An error occurred while creating device for id '$item->{id}': $cmdret";
			}

		} else {

			my $deviceHash = $modules{TadoDevice}{defptr}{$code};

			CommandAttr(undef, "$deviceName room Tado");
			CommandAttr(undef, "$deviceName subType " . ($item->{deviceType} eq 'IB01' ? "bridge" : "thermostat"));
			$deviceHash->{deviceType} = $item->{deviceType};
			$deviceHash->{serialNo} = $item->{serialNo};
			$deviceHash->{shortSerialNo} = $item->{shortSerialNo};
			$deviceHash->{capabilities} = join(' ', $item->{characteristics}->{capabilities});

		}
	}
	return undef;
}

sub _autocreateMobileDevice 
{
    my $hash         = shift;
    my $item 		 = shift;
    my $name         = $hash->{NAME};


	readingsSingleUpdate($hash, "MobileDevice_".$item->{id} , $item->{name},1 );
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

sub _autocreateWeatherChannel 
{
    my $hash         = shift;
    my $item 		 = shift;
    my $name         = $hash->{NAME};


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
		}
	}
	return undef;
}

sub Processing_Dpoint_GetZones 
{
    my $hash         = shift;
    my $decoded_data = shift;
    my $name         = $hash->{NAME};

	readingsBeginUpdate($hash);

	my $ZoneCount = 0;
	my %ZoneIds = ();

	for my $item( @{$decoded_data} ){

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
	readingsEndUpdate($hash, 1);
	return undef;
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
		readingsSingleUpdate($hash,'state','polling',0);
	}


	GetZoneTemperatures($hash);
	WriteToCloudAPI( $hash, 'getWeather', 'GET', undef);
	WriteToCloudAPI( $hash, 'getMobileDevices', 'GET', undef);
	WriteToCloudAPI( $hash, 'getAirComfort', 'GET', undef);
	WriteToCloudAPI( $hash, 'getDevices', 'GET', undef);
	WriteToCloudAPI( $hash, 'getPresenceStatus', 'GET', undef);	

}

sub Write ($$)
{
	my ($hash, $code, $zoneID, @params) = @_;
	my $name = $hash->{NAME};

	if (ReadingsVal($name, 'state', 'unknown') =~ /\[Error\]/ || ReadingsVal($name, 'state', 'unknown') =~ /preparing/ || ReadingsVal($name, 'state', 'unknown') =~ /initializing/) {
		Log3 $name, 4, "Device is in error state or not yet ready. No commands will be executed.";
		return undef;
	}

	if ($code eq 'Temp')
	{
	   return WriteTemperature2Tado($hash, $zoneID, @params);
	}

	if ($code eq 'EarlyStart')
	{
		my %message ;
		$message{'enabled'} = shift @params;

		WriteToCloudAPI( $hash, 'setEarlyStart', 'PUT', \%message, $zoneID );
	}

	if ($code =~ 'geoTrackingEnabled|onDemandLogRetrievalEnabled|specialOffersEnabled')
	{
		my %message;
		$message{$code} = shift @params;

		WriteToCloudAPI( $hash, 'UpdateMobileDevice', 'PUT', \%message , $zoneID);
	}

	if ($code eq 'pushNotifications')
	{
		my %message;
		my @keys = qw(
			lowBatteryReminder
			awayModeReminder
			homeModeReminder
			energySavingsReportReminder
			openWindowReminder
			energySavingsReportReminder
			openWindowReminder
		);

		for my $key (@keys) {
			my $val = shift @params;
			$message{'pushNotifications'}->{$key} = $val if defined($val) && $val ne '';
		}

		WriteToCloudAPI( $hash, 'UpdateMobileDevice', 'PUT', \%message, $zoneID);
	}

	if ($code eq 'Update')
	{
		GetZoneTemperatures($hash);
		WriteToCloudAPI( $hash, 'getEarlyStart', 'GET', undef, $zoneID);
		WriteToCloudAPI( $hash, 'getWeather', 'GET', undef);
		WriteToCloudAPI( $hash, 'getMobileDevices', 'GET', undef, $zoneID), ;
		WriteToCloudAPI( $hash, 'getAirComfort', 'GET', undef, $zoneID);
		WriteToCloudAPI( $hash, 'getDevices', 'GET', undef, $zoneID);

	}

	if ($code eq 'Hi')
	{
  		WriteToCloudAPI( $hash, 'identifyDevice', 'POST', undef, $zoneID);
	}

	return undef;
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
    <i>Tado</i> provides an interface to the Tado cloud. This module allows you to read and write temperature and settings from/to Tado via its cloud API. Communication is based on the reverse-engineering work by Stephen C. Phillips. See <a href="http://blog.scphillips.com/posts/2017/01/the-tado-api-v2/">his blog</a> for more details.

    Not all Tado features are implemented. Currently, this module supports interaction with zones (rooms) and devices. Devices cannot be controlled directly; instead, all interactions must occur via zones. Configuration such as registering devices or assigning them to rooms must be done via the Tado app or website.

    This FHEM device acts as a bridge (like HueBridge or CUL). A separate device of type <code>TadoDevice</code> is created per zone or hardware device.

    <br><br>
    <b>Supported Features:</b>
    <ul>
        <li><b>Bridge</b>
            <ul>
                <li>Manages communication with the Tado cloud and provides readings for status and last updates.</li>
                <li><b>Presence Status:</b> Indicates if at least one mobile device is at home.</li>
                <li><b>Air Comfort:</b> Shows overall air comfort for the home.</li>
            </ul>
        </li>
        <li><b>Zone (Room)</b>
            <ul>
                <li><b>Temperature:</b> Current temperature and target setting including Tado control modes (manual, auto).</li>
                <li><b>Air Comfort:</b> Zone-specific air quality indicator.</li>
            </ul>
        </li>
        <li><b>Device</b>
            <ul>
                <li><b>Connection State:</b> Last seen timestamp.</li>
                <li><b>Battery Level:</b> Current battery state.</li>
                <li><b>Say Hi:</b> Displays a message on the device to help identify it.</li>
            </ul>
        </li>
        <li><b>Mobile Device</b>
            <ul>
                <li><b>Configuration:</b> View-only info about type and config.</li>
                <li><b>Presence:</b> Indicates if the mobile device is home or away.</li>
            </ul>
        </li>
        <li><b>Weather</b>
            <ul>
                <li>Cloud-sourced outside weather data and solar intensity (not measured).</li>
            </ul>
        </li>
    </ul>

    <br>
    <b>Authentication (as of March 2025):</b>
    <br>
    Tado has introduced a new device-based authentication. Username/password login is no longer supported. See <a href="https://support.tado.com/en/articles/8565472-how-do-i-authenticate-to-access-the-rest-api">Tado Support Article</a>.

    <ul>
        <li>Execute <code>set &lt;device&gt; authenticate</code> to initiate authentication. This registers FHEM as a new device and returns a device code.</li>
        <li>Follow the URL shown in the response to log into Tado and confirm the new device.</li>
        <li>After confirmation, the module will poll for updates and complete authentication automatically.</li>
    </ul>

    <br><br>
    <a name="Tadodefine"></a>
    <b>Define</b>
    <ul>
        <code>define &lt;name&gt; Tado &lt;interval&gt;</code><br><br>
        Example: <code>define TadoBridge Tado 120</code><br><br>
        This creates a Tado bridge device. The polling interval (in seconds) controls how often data is refreshed.
    </ul>

    <br><br>
    <a name="Tadoset"></a>
    <b>Set</b>
    <ul>
        <code>set &lt;name&gt; &lt;option&gt;</code><br><br>
        Available options:
        <ul>
            <li><i>authenticate</i>: Starts device-based login (overwrites existing authentication).</li>
            <li><i>interval</i>: Changes the polling interval.</li>
            <li><i>start</i>: Starts automatic polling.</li>
            <li><i>stop</i>: Stops automatic polling.</li>
            <li><i>presence</i>: Manually set global presence to HOME or AWAY. Avoid this if geofencing is enabled.</li>
        </ul>
    </ul>

    <br><br>
    <a name="Tadoget"></a>
    <b>Get</b>
    <ul>
        <code>get &lt;name&gt; &lt;option&gt;</code><br><br>
        Available options:
        <ul>
            <li><i>home</i>: Fetches home ID and name. Auto-executed during device creation.</li>
            <li><i>zones</i>: Fetches all Tado zones and creates corresponding FHEM devices.</li>
            <li><i>update</i>: Triggers a one-time update (zones, presence, weather, devices, mobile devices).</li>
        </ul>
    </ul>

    <br><br>
    <a name="Tadoattr"></a>
    <b>Attributes</b>
    <ul>
        <code>attr &lt;name&gt; &lt;attribute&gt; &lt;value&gt;</code><br><br>
        Available attributes:
        <ul>
            <li><i>generateDevices</i>: yes/no — Create Tado hardware devices. Default: no.</li>
            <li><i>generateMobileDevices</i>: yes/no — Create mobile devices for presence detection. Default: no.</li>
            <li><i>generateWeather</i>: yes/no — Create weather device. Default: no.</li>
        </ul>
    </ul>

    <br><br>
    <a name="Tadoreadings"></a>
    <b>Generated Readings</b><br>
    (Sorted alphabetically)
    <br><br>
    <ul>
        <li><b>DeviceCount</b>: Number of hardware devices (only if <code>generateDevices=yes</code>).</li>
        <li><b>HomeID</b>: Tado home identifier.</li>
        <li><b>HomeName</b>: Tado home name.</li>
        <li><b>LastUpdate_AirComfort</b>: Timestamp of last air comfort update.</li>
        <li><b>LastUpdate_Devices</b>: Timestamp of last hardware device update.</li>
        <li><b>LastUpdate_MobileDevices</b>: Timestamp of last mobile device update (only if <code>generateMobileDevices=yes</code>).</li>
        <li><b>LastUpdate_Weather</b>: Timestamp of last weather update (only if <code>generateWeather=yes</code>).</li>
        <li><b>LastUpdate_Zones</b>: Timestamp of last zone/room update.</li>
        <li><b>MobileDeviceCount</b>: Number of detected mobile devices (only if <code>generateMobileDevices=yes</code>).</li>
        <li><b>MobileDevice_&lt;deviceid&gt;</b>: Name of each detected mobile device.</li>
        <li><b>Presence</b>: Global presence status (HOME or AWAY).</li>
        <li><b>ZoneCount</b>: Number of zones (rooms) detected.</li>
        <li><b>Zone_&lt;zoneid&gt;_Name</b>: Name of each zone.</li>
        <li><b>airComfort_freshness</b>: Overall air freshness indicator for the home.</li>
        <li><b>airComfort_lastWindowOpen</b>: Timestamp of the last open window detection.</li>
        <li><b>last_error</b>: Last error message and timestamp.</li>
        <li><b>state</b>: Current internal state of the module.
            <br>The following states are possible:
            <ul>
                <li><i>preparing</i>: The module is initializing after startup and not ready yet.</li>
                <li><i>initializing</i>: Authentication is completed; initial data is being loaded.</li>
                <li><i>initialized</i>: The module is ready and operational.</li>
                <li><i>polling</i>: The module is actively polling for updates.</li>
                <li><i>[Error]</i>: An error occurred during operation. See <code>last_error</code> for details.</li>
            </ul>
        </li>
    </ul>

</ul>

=end html

=cut
