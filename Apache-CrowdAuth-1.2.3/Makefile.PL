use 5.008000;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

my $succeeded = 0;

print "\nChecking for required modules:\n\n";

my %requiredModules = (
    "SOAP::Lite"   => 0,
    "Cache::Cache" => 0,
    "Error"        => 0,
    "CGI::Cookie" => 0,
    "APR::SockAddr" => 0,
);

my @moduleNames = sort(keys(%requiredModules));

foreach my $module (@moduleNames)
{
    eval "require $module";
    print "$module is installed... "
        . ($@ ? "no" : "yes") . "\n";

    $succeeded++ unless ($@);
}

unless ($succeeded == scalar(@moduleNames))
{
    print "\nYou must install " . join(", ", @moduleNames) . "\n";
    exit;
}
print "\n";


WriteMakefile(
    NAME              => 'Apache::CrowdAuth',
    VERSION_FROM      => 'lib/Apache/CrowdAuth.pm', # finds $VERSION
    PREREQ_PM         => {}, # e.g., Module::Name => 1.1
    ($] >= 5.005 ?     ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM  => 'lib/Apache/CrowdAuth.pm', # retrieve abstract from module
       AUTHOR         => 'Atlassian Pty Ltd <andrewr@>') : ()),
);
