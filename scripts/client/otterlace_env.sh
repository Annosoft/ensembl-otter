
# The installation script will append the proper values to these
# lines.  (It stops substituting at the first non-assignment code.)
version=
anasoft=
OTTER_HOME=


# check that the installation script has set things up
if [ -z "$version" ]
then
    echo "This script has been improperly installed!  Consult the developers!" >&2
    exit 1
fi


# Do not assume client is Inside.
#
# This will not re-configure for laptops which transition from guest
# to/from wired.
case "$( hostname -f 2>/dev/null || hostname )" in
    *.sanger.ac.uk)
        # On wired network.  Need proxy to fetch external resources,
        # but not to reach the Otter Server or a local Apache
        http_proxy=http://webcache.sanger.ac.uk:3128
        export http_proxy
        no_proxy=.sanger.ac.uk,localhost
        export no_proxy
        ;;
esac

# Copy the *_proxy variables we want into *_PROXY, to simplify logic
if [ -n "$http_proxy" ]; then
    HTTP_PROXY="$http_proxy"
    export HTTP_PROXY
else
    unset  HTTP_PROXY
fi
if [ -n "$no_proxy" ]; then
    NO_PROXY="$no_proxy"
    export NO_PROXY
else
    unset  NO_PROXY
fi

# Copy http_proxy to https_proxy
if [ -n "$http_proxy" ]; then
    https_proxy="$http_proxy"
    HTTPS_PROXY="$http_proxy"
    export https_proxy HTTPS_PROXY
else
    unset  https_proxy HTTPS_PROXY
fi


export OTTER_HOME

LD_LIBRARY_PATH=
export LD_LIBRARY_PATH

anasoft_distro="$anasoft/distro/$( $anasoft/bin/anacode_distro_code )"

otterbin="\
$OTTER_HOME/bin:\
$anasoft_distro/bin:\
$anasoft/bin:\
/software/pubseq/bin/EMBOSS-5.0.0/bin:\
/software/perl-5.12.2/bin\
"

if [ -n "$ZMAP_BIN" ]
then
    otterbin="$ZMAP_BIN:$otterbin"
    echo "  Hacked otterbin for ZMAP_BIN=$ZMAP_BIN" >&2
fi

if [ -n "$PATH" ]
then
    PATH="$otterbin:$PATH"
else
    PATH="$otterbin"
fi
export PATH

# Settings for wublast needed by local blast searches
WUBLASTFILTER=$anasoft/bin/wublast/filter
export WUBLASTFILTER
WUBLASTMAT=$anasoft/bin/wublast/matrix
export WUBLASTMAT

# Some setup for acedb
ACEDB_NO_BANNER=1
export ACEDB_NO_BANNER

#cp -f "$OTTER_HOME/acedbrc" ~/.acedbrc

PERL5LIB="\
$OTTER_HOME/PerlModules:\
$OTTER_HOME/ensembl-otter/modules:\
$OTTER_HOME/ensembl-analysis/modules:\
$OTTER_HOME/ensembl/modules:\
$OTTER_HOME/ensembl-variation/modules:\
$OTTER_HOME/lib/perl5:\
$OTTER_HOME/ensembl-otter/tk:\
"

osname="$( uname -s )"

case "$osname" in
    Darwin)
        PERL5LIB="${PERL5LIB}:\
$anasoft/lib/site_perl:\
$anasoft/lib/perl5/site_perl:\
$anasoft/lib/perl5/vendor_perl:\
$anasoft/lib/perl5\
"
        ;;

    *)
        PERL5LIB="${PERL5LIB}:\
$anasoft_distro/lib:\
$anasoft_distro/lib/site_perl:\
$anasoft/lib:\
$anasoft/lib/site_perl\
"
        ;;
esac

if [ -n "$ZMAP_LIB" ]
then
    PERL5LIB="$ZMAP_LIB:$ZMAP_LIB/site_perl:$PERL5LIB"
    echo "  Hacked PERL5LIB for ZMAP_LIB=$ZMAP_LIB" >&2
fi

export PERL5LIB
