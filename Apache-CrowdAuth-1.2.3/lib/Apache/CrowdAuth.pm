package Apache::CrowdAuth;

use 5.008000;
use strict;
use warnings;

use Exporter;
use Cache::FileCache;
use Atlassian::Crowd;
use APR::SockAddr;
use CGI::Cookie;
use Digest::SHA1  qw(sha1 sha1_hex sha1_base64);

$SOAP::Constants::DO_NOT_USE_XML_PARSER = 1;

# Uncomment the following line (and comment out the line below it) to
# enable debug output of the SOAP messages.
# use SOAP::Lite +trace => qw (debug);
use SOAP::Lite;

our @ISA = qw(Exporter);

our $VERSION = '1.2.3';


# Use correct API for loaded version of mod_perl.
#
BEGIN {

    unless ( $INC{'mod_perl.pm'} ) {

        my $class = 'mod_perl';

        if ( exists $ENV{MOD_PERL_API_VERSION} && $ENV{MOD_PERL_API_VERSION} == 2 ) {
            $class = 'mod_perl2';
        }

        eval "require $class";
    }

    my @import = qw( OK HTTP_UNAUTHORIZED SERVER_ERROR );

    if ( $mod_perl::VERSION >= 1.999022 ) { # mod_perl 2.0.0 RC5
        require Apache2::RequestRec;
        require Apache2::RequestUtil;
        require Apache2::RequestIO;
        require Apache2::Log;
        require Apache2::Connection;
        require Apache2::Const;
        require Apache2::Access;
        Apache2::Const->import(@import);
     }
     elsif ( $mod_perl::VERSION >= 1.99 ) {
        require Apache::RequestRec;
        require Apache::RequestUtil;
        require Apache::RequestIO;
        require Apache::Log;
        require Apache::Connection;
        require Apache::Const;
        require Apache::Access;
        Apache::Const->import(@import);
    }
    else {
        require Apache;
        require Apache::Log;
        require Apache::Constants;
        Apache::Constants->import(@import);
    }
}

use constant MP2 => $mod_perl::VERSION >= 1.999022 ? 1 : 0;

# ---------------------------------------------------------------------------

# Create the cache 
sub init_cache($) {
  my $r = shift;
  
  my $cache;
  
  my $cache_location = $r->dir_config('CrowdCacheLocation');
  
  if(!defined $cache_location) {
    # use default location $TEMP/FileCache
    $cache = new Cache::FileCache( { namespace => $r->auth_name()} );
  } else {
    $cache = new Cache::FileCache( { cache_root => $cache_location,
                      namespace => $r->auth_name()} );
  } 

  return $cache;  
}

# ---------------------------------------------------------------------------

sub read_options($) { my $r = shift; my $rlog = $r->log;

  # Get parameters from the apache conf file
  my $app_name = $r->dir_config('CrowdAppName');
  my $app_credential = $r->dir_config('CrowdAppPassword');
  my $cache_enabled = $r->dir_config('CrowdCacheEnabled') || 'on';
  my $cache_expiry = $r->dir_config('CrowdCacheExpiry') || '30';
  my $cache_expiry_app = $r->dir_config('CrowdCacheExpiryApp') || '3600';
  my $cookie_name = $r->dir_config('CrowdCookieName') || 'crowd.token_key';
  my $soaphost = $r->dir_config('CrowdSOAPURL') || "http://localhost:8095/crowd/services/SecurityServer";

  $cache_expiry = $cache_expiry.' seconds';
  $cache_expiry_app = $cache_expiry_app.' seconds';
  
  my $disable_parser = $r->dir_config('CrowdUseInternalXMLParser') || 'yes';
  
  # By default, SOAP::Lite uses XML::Parser, which uses libexpat, which can
  # conflict with some apache builds and cause segfaults. This option tells
  # SOAP::Lite to use an internal pure-perl parser
  if(defined($disable_parser) && ($disable_parser eq 'yes')) {
    $SOAP::Constants::DO_NOT_USE_XML_PARSER = 1;
  }
  
  return ($app_name, $app_credential, $cache_enabled, $cache_expiry, $cache_expiry_app, $soaphost, $cookie_name);
} 

sub read_options_cookies($) { my $r = shift;
  # Get parameters from the apache conf file
  my $cookie_enable = $r->dir_config('CrowdCookieSet') || 'true';
  my $cookie_name = $r->dir_config('CrowdCookieName') || 'crowd.token_key';
  
  return ($cookie_enable, $cookie_name);
} 

sub get_domain_config($$$$$$) {
  my ($r, $app_name, $app_credential, $soaphost, $cache, $cache_expiry) = @_; 
  
  return ('false', 'false');
}
# ---------------------------------------------------------------------------

sub get_app_token($$$$$$) {
  my ($r, $app_name, $app_credential, $soaphost, $cache, $cache_expiry) = @_; 
  
  my $apptoken;
  my $rlog = $r->log;
  
  if(defined $cache) {
    $apptoken = $cache->get($app_name.'___APP');
  }
  
  if(!defined $apptoken) {
    $rlog->debug('CrowdAuth: About to auth app ['.$app_name.','.sha1_base64($app_credential).','.$cache_expiry.']');
    
    $apptoken = Atlassian::Crowd::authenticate_app($soaphost, $app_name, $app_credential);
    
    if((defined $cache) && (defined $apptoken)) {
      $rlog->debug('CrowdAuth: app token cache miss!...');
      
      # purge whenever we re-auth the app to clear out expired entries
      $cache->purge();
      $cache->set($app_name.'___APP', $apptoken, $cache_expiry);
    }
    
  } else {
    $rlog->debug('CrowdAuth: app token cache hit!...'.$apptoken);
  }
    
  return $apptoken;
}

sub set_cookie($$$$$$$) {
  my ($r, $principal_token, $app_name, $apptoken, $soaphost, $cache, $cache_expiry) = @_;
  my $rlog = $r->log;
  
  my ($cookie_enable, $cookie_name) = read_options_cookies($r);
  
  if ($cookie_enable eq 'false') {
    return;
  }
  
  my $cookie;
  
  my ($cookie_domain, $cookie_secure) = get_domain_config($r, $app_name, $apptoken, $soaphost, $cache, $cache_expiry);
  
  # Add headers Cookie, used by upstream servers
  $r->headers_in->add('Cookie' => $cookie_name.'='.$principal_token.';');
  
  $cookie = new CGI::Cookie(-name=> $cookie_name, -value=>"$principal_token", -httponly=>1);
  if ($cookie_secure eq 'true') {
    $cookie->secure(1);
  }
  if ($cookie_domain ne 'false') {
    $cookie->domain($cookie_domain);
  }
  
  my $add_cookie = 1;
  my @table = $r->headers_out->get('Set-Cookie');
  foreach my $val (@table) {
    if ($val =~ /.*$cookie_name.*/) {
      $add_cookie = 0;
    }
  }
  if ($add_cookie == 1) {
    $rlog->debug('Set-Cookie '.$cookie->name.' : '.$cookie->value);
    $r->headers_out->add('Set-Cookie' => $cookie);
  }
}
# ---------------------------------------------------------------------------

# Entry Point
#
sub handler {
  my $r = shift;

  my $rlog = $r->log;
    
  my $cache;
  
  my ($app_name, $app_credential, $cache_enabled, $cache_expiry, $cache_expiry_app, $soaphost, $cookie_name) = read_options($r); 
  
  my $apptoken;
  
  if($cache_enabled eq 'on') {
    # Initialise the cache
    $cache = init_cache($r);
  }
     
  my %validation_factors;
  $validation_factors{'remote_address'} = $r->connection()->remote_addr->ip_get();
  my $x_forwarded_for = $r->headers_in->get('X-Forwarded-For');
  if (defined($x_forwarded_for)) {
    $validation_factors{'remote_address'} = $x_forwarded_for;
  } 
  $validation_factors{'User-Agent'} = $r->headers_in->get('User-Agent');
  
  my $string_validation_factors = '';
  while (my ($name, $value) = each %validation_factors) {
    $string_validation_factors .= $name.'-'.$value.'_';
  }
  
  my %cookies = parse CGI::Cookie($r->headers_in->get('Cookie'));
  foreach (keys %cookies) {
    my $c = $cookies{$_};
          #$rlog->warn('Cookie : name = '.$c->name.', value = '.$c->value);
          if ($c->name eq $cookie_name) {
            $rlog->debug('Try to validate token : '.$c->value);
            if($cache_enabled eq 'on') {
              my $entry = $cache->get('token_'.$string_validation_factors.'_'.$c->value);
              if (defined $entry) {
                $rlog->debug('Token found in cache, user authenticated');
                return OK;
              }
            }
            $apptoken = get_app_token($r, $app_name, $app_credential, $soaphost, $cache, $cache_expiry_app);
            my $res = Atlassian::Crowd::validate_token($soaphost, $app_name, $apptoken, $c->value, %validation_factors);
            if ($res eq 'true') {
              $rlog->debug('Token valid, user authenticated');
              if($cache_enabled eq 'on') {
                $cache->set('token_'.$c->value, 'OK', $cache_expiry);
              }   
              return OK;  
            }
            else {
              $rlog->debug('Invalid token, try normal authentification');
            }
          }
      }

  my ($status, $password) = $r->get_basic_auth_pw;
  return $status unless $status == OK;
  
  my $user = $r->user;
  unless($user and $password) {
     $r->note_basic_auth_failure;
     $rlog->debug("Both a username and password must be provided");
     return HTTP_UNAUTHORIZED;
  }
  
  # Both the application name and credential password need to be defined.
  if(!defined($app_name) || !defined($app_credential)) {
    $r->log_error("CrowdAuth: CrowdAppName or CrowdAppPassword is not defined");
    $r->note_basic_auth_failure;
    return HTTP_UNAUTHORIZED;
  }
  
  if (!defined $apptoken) {
    $apptoken = get_app_token($r, $app_name, $app_credential, $soaphost, $cache, $cache_expiry_app);
  }
    
  if(defined $apptoken) {
    $rlog->debug('CrowdAuth: auth app OK...'.$apptoken);
    
    my $pCacheHit = 0;
    
    # is the principal in the cache?
    if($cache_enabled eq 'on') {
      my $principalEntry = $cache->get('user_'.$string_validation_factors.'_'.$user);
      my $principal_token = $cache->get('token_for_user_'.$string_validation_factors.'_'.$user);
      
      if(defined $principalEntry && defined $principal_token) {
        # check the passwords are the same
        my $sha1Password = sha1_base64($password);
        if($sha1Password eq $principalEntry) {
          $pCacheHit = 1;
          $rlog->debug('CrowdAuth: auth principal cache hit...'.$user.', '.$sha1Password);
          set_cookie($r, $principal_token, $app_name, $apptoken, $soaphost, $cache, $cache_expiry_app);
        }
      }
    }
        
    if($pCacheHit == 0) {
      # We've got a new app token - try to authenticate the user
      my $principal_token = Atlassian::Crowd::authenticate_principal($soaphost, $app_name, $apptoken, $user, $password, %validation_factors);
      if (!defined $principal_token) {
        # failed to auth user.
        $rlog->warn('CrowdAuth: Failed to authenticate '.$user.'.');
        $r->note_basic_auth_failure;
        return HTTP_UNAUTHORIZED;
      }
      
      if($cache_enabled eq 'on') {
        # cache the authentication
        $cache->set('user_'.$string_validation_factors.'_'.$user, sha1_base64($password), $cache_expiry);
        $cache->set('token_for_user_'.$string_validation_factors.'_'.$user, $principal_token, $cache_expiry);
        $cache->set('token_'.$string_validation_factors.'_'.$principal_token, 'OK', $cache_expiry);
      }
      
      set_cookie($r, $principal_token, $app_name, $apptoken, $soaphost, $cache, $cache_expiry_app);
    }
  } else {
    $rlog->error('CrowdAuth: Failed to authenticate application.');
    # failed to auth app.
    $r->note_basic_auth_failure;
    return HTTP_UNAUTHORIZED;
  }
    
  $rlog->debug('CrowdAuth: Principal '.$user.' authenticated OK');
  return OK;
}


# ---------------------------------------------------------------------------



1;
__END__


=head1 NAME

Apache::CrowdAuth - Apache authentication handler that uses Atlassian Crowd.

=head1 SYNOPSIS

<Location /location>
  AuthName crowd
  AuthType Basic

  PerlAuthenHandler Apache::CrowdAuth
  PerlSetVar CrowdAppName appname
  PerlSetVar CrowdAppPassword apppassword
  PerlSetVar CrowdSOAPURL http://localhost:8095/crowd/services/SecurityServer
  PerlSetVar CrowdCacheEnabled on
  PerlSetVar CrowdCacheLocation /tmp/CrowdAuthCache
  PerlSetVar CrowdCacheExpiry 300

  require valid-user
</Location>

=head1 DESCRIPTION

This Module allows you to configure Apache to use Atlassian Crowd to 
handle basic authentication.
  
See http://confluence.atlassian.com/x/rgGY

for full documentation.

=head2 EXPORT

None by default.



=head1 SEE ALSO

http://www.atlassian.com/crowd

=head1 AUTHOR

Atlassian.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2007 by Atlassian

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.5 or,
at your option, any later version of Perl 5 you may have available.

=cut
