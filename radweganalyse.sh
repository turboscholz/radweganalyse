#!/bin/bash
set -Eeo pipefail

usage() {
  cat <<EOF
This sript takes a csv file with acceleration measurements and a csv
file with location messurements from the Android app "phyphox" and
generates a gpx file out of it in which the elevation values are actually
the z acceleration values.

Why is this information usefull? It can be used with a standard gpx viewer
to see how the bike lane quality is and where problematic locations are
"hidden" on the bike path.

Dependencies: GMT's "sample1d", gpsbable, basic linux commands
              python for finding largest values, pandas python package

-h, --help            Print this help and exit
-v, --verbose         Print script debug info
-o, --output          The output file name can be overridden, default is "xyz_data.gpx"
-l, --locations       This is the input file of the phyphox experiment, default is "Location.csv"
-a, --accelerations   This is the acceleration measurement file from phyphox
                      where the gravitational acceleration is not taken into account, default "Accelerometer.csv"
                      This file does not need to be existing if the file "Linear Acceleration.csv" is available.
-b, --bad             The number of gps positions this script should find where the acceleration in z direction is exceptional, default 5
-t, --window          The time window in seconds in which a no other value with high z accelerations will be searched, default 2
    --unresampled     Do not create a gpx file with unresampled coordinate data
EOF
  exit
}

# Use colors like this:
# msg "${RED}Read parameters:${NOFORMAT}"
setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg="${RED}${1}${NOFORMAT}"
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

# Default values (adjustable by user options):
#
# The output file name can be overridden by the -o option
OUTPUTFILENAME="xyz_data.gpx"
#
# These are the files of the phyphox experiment used as input here
# Their names can be overridden by -l and -a options
LOCATIONFILE="Location.csv"
#
# This is the acceleration measurement file from phyphox where the gravitational
# acceleration is not taken into account
ACCELEROMETERFILE="Accelerometer.csv"
#
# This file is the acceleration measurement from phyphox where the gravitational
# acceleration is taken into account:
ACCELEROMETERFILE_ALTERNATE="Linear Acceleration.csv"
#
# The number of gps positions this script should find where the acceleration
# in z direction is exceptional
BAD_STREET_POSITIONS="5"
#
# The time window in seconds in which a no other value with high z accelerations
# will be searched
TIME_WINDOW="2"
#
# Do not create a gpx file with unresampled coordinate data
UNRESAMPLED=NO

# Parse the arguments, see https://stackoverflow.com/a/14203146
for i in "$@"
do
case $i in
    -h | --help) usage ;;
    -o|--output)
    OUTPUT_ARG="$2"
    shift # past argument
    shift # past value
    ;;
    -l|--locations)
    LOCATIONFILE_ARG="$2"
    shift # past argument
    shift # past value
    ;;
    -a|--accelerations)
    ACCELEROMETERFILE_ARG="$2"
    shift # past argument
    shift # past value
    ;;
    -b)
    BAD_STREET_POSITIONS_ARG="$2"
    shift # past argument
    shift # past value
    ;;
    -t)
    TIME_WINDOW_ARG="$2"
    shift # past argument
    shift # past value
    ;;
    --unresampled)
    UNRESAMPLED=YES
    shift # past argument with no value
    ;;
    *)
          # unknown option
    ;;
esac
done


################################################################################

# Detect which acceleration file is available, set GVALUE accordingly
GVALUE="0.0"
if [ "${ACCELEROMETERFILE_ARG}" == "" ]; then
    if [ ! -f "$ACCELEROMETERFILE" ]; then
	if [ ! -f "$ACCELEROMETERFILE_ALTERNATE" ]; then
	    echo "Acceleration input file not found"
	    exit 1
	else
	    ACCELEROMETERFILE="$ACCELEROMETERFILE_ALTERNATE"
	    GVALUE="9.81"
	fi
    fi
fi

# Assign values of script arguments
if [ "${OUTPUT_ARG}" != "" ]; then
    OUTPUTFILENAME="${OUTPUT_ARG}"
fi
if [ "${LOCATIONFILE_ARG}" != "" ]; then
    LOCATIONFILE="${LOCATIONFILE_ARG}"
fi
if [ "${ACCELEROMETERFILE_ARG}" != "" ]; then
    ACCELEROMETERFILE="${ACCELEROMETERFILE_ARG}"
fi
if [ "${BAD_STREET_POSITIONS_ARG}" != "" ]; then
    BAD_STREET_POSITIONS="${BAD_STREET_POSITIONS_ARG}"
fi
if [ "${TIME_WINDOW_ARG}" != "" ]; then
    TIME_WINDOW="${TIME_WINDOW_ARG}"
fi

# Just leave the time and acceleration in z-direction
ACCLS=$(mktemp /tmp/XXXXXX)
cut "$ACCELEROMETERFILE" -d, -f1,4 > $ACCLS

# Leave time, latitude, longitue, speed
COORDS=$(mktemp /tmp/XXXXXX)
cut $LOCATIONFILE -d, -f1-3,5 > $COORDS

# Remove the header line from each data file
sed -i '1d;' $ACCLS
sed -i '1d;' $COORDS

COORDS_RESAMPLED=$(mktemp /tmp/XXXXXX)
gmt sample1d -s $COORDS -T${ACCLS} > $COORDS_RESAMPLED

# Remove timestamps from acceleration file
Z_ACCELS=$(mktemp /tmp/XXXXXX)
cut $ACCLS -d, -f2 > $Z_ACCELS

rm $ACCLS

sed -i 's/\t/, /g;' $COORDS_RESAMPLED

MERGED=$(mktemp /tmp/XXXXXX)
paste -d, $COORDS_RESAMPLED $Z_ACCELS > $MERGED
rm $COORDS_RESAMPLED
rm $Z_ACCELS

# Remove lines which start with a comma after merging
sed -i '/^,/d' $MERGED

# This file can be used later to analyze the data with a Python script
MERGED_WITH_TIME=$(mktemp /tmp/XXXXXX)
cut -d, -f1-5 $MERGED > $MERGED_WITH_TIME
sed -i '1i time, y, x, speed, z' $MERGED_WITH_TIME # Include header

# This file will be used to export the final results to.
# We don't need time information in it.
MERGED_WO_TIME=$(mktemp /tmp/XXXXXX)
cut -d, -f2,3,4,5 $MERGED > $MERGED_WO_TIME
sed -i '1i y, x, speed, z' $MERGED_WO_TIME # Include header
rm $MERGED

# Create the gpx file with acceleration data
MERGED_WO_TIME_GPX=$(mktemp /tmp/XXXXXX)
gpsbabel -t -i unicsv -f $MERGED_WO_TIME -o gpx -F $MERGED_WO_TIME_GPX
rm $MERGED_WO_TIME

# Create the unresampled gpx file (from the original data)
if [ $UNRESAMPLED == "YES" ]; then
    COORDS_WO_TIME=$(mktemp /tmp/XXXXXX)
    cut -d, -f2,3 $COORDS > $COORDS_WO_TIME
    COORDS_WO_TIME_CONVERTED=$(mktemp /tmp/XXXXXX)
    OLDIFS=$IFS
    IFS=','
    while read LAT LON
    do
	LAT_CONV=$(echo $LAT | awk '{printf("%3.9f",$0);}')
	LON_CONV=$(echo $LON | awk '{printf("%3.9f",$0);}')
	echo "$LAT_CONV, $LON_CONV" >> $COORDS_WO_TIME_CONVERTED
    done < $COORDS_WO_TIME
    IFS=$OLDIFS

    sed -i '1i lat, long' $COORDS_WO_TIME_CONVERTED # Include header
    COORDS_WO_TIME_CONVERTED_GPX=$(mktemp /tmp/XXXXXX)
    gpsbabel -t -i unicsv -f $COORDS_WO_TIME_CONVERTED -o gpx -F $COORDS_WO_TIME_CONVERTED_GPX
    rm $COORDS_WO_TIME
    rm $COORDS_WO_TIME_CONVERTED
fi

rm $COORDS

# Get the coordinates with the highest z values in a seperate gpx file
HIGH_Z_COORDS=$(mktemp /tmp/XXXXXX)

# Get the path of this script
SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

# Find the gps coordinates where the highest z acceleration values happened
python "$SCRIPTPATH"/acceleration_selection.py -i $MERGED_WITH_TIME -b $BAD_STREET_POSITIONS -t $TIME_WINDOW -o $HIGH_Z_COORDS -g $GVALUE

rm $MERGED_WITH_TIME

TIME_SORTED_Z_COORDS=$(mktemp /tmp/XXXXXX)
cat $HIGH_Z_COORDS | (read -r; printf "%s\n" "$REPLY"; sort -g) | cut -d, -f2,3,4,5 > $TIME_SORTED_Z_COORDS

TIME_SORTED_Z_COORDS_GPX=$(mktemp /tmp/XXXXXX)
gpsbabel -i unicsv -f $TIME_SORTED_Z_COORDS -o gpx -F $TIME_SORTED_Z_COORDS_GPX
rm $HIGH_Z_COORDS
rm $TIME_SORTED_Z_COORDS

# Merge the last gpx into the first one and create a seperate output file
gpsbabel -i gpx -f $TIME_SORTED_Z_COORDS_GPX -i gpx -f $MERGED_WO_TIME_GPX -o gpx -F $OUTPUTFILENAME
rm $MERGED_WO_TIME_GPX

if [ $UNRESAMPLED == "YES" ]; then
    gpsbabel -i gpx -f $TIME_SORTED_Z_COORDS_GPX -i gpx -f $COORDS_WO_TIME_CONVERTED_GPX -o gpx -F $(echo $OUTPUTFILENAME | sed 's/\(^.*\)\.gpx/\1_unresampled.gpx/g')
    rm $COORDS_WO_TIME_CONVERTED_GPX
fi

rm $TIME_SORTED_Z_COORDS_GPX
