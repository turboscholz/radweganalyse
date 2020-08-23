#!/bin/bash
set -e

# This sript takes a csv file with acceleration measurements and a csv
# file with location messurements from the Android app "phybox" and
# generates a gpx file out of it in which the elevation values are actually
# the z acceleration values.
# 
# Why is this information usefull? It can be used with a standard gpx viewer
# to see how the bike lane quality is and where problematic locations are
# "hidden" on the bike path.

# Dependencies: GMT's "sample1d", gpsbable, basic linux commands
#               python for finding largest values, pandas python package

# The output file name can be overridden by the -o option
OUTPUTFILENAME="xyz_data.gpx"

# These are the files of the phybox experiment used as input here
# Their names can be overridden by -l and -a options
LOCATIONFILE="Location.csv"
ACCELEROMETERFILE="Accelerometer.csv"

# Defaultvalues:
#
# Do not create a gpx file with unresampled coordinate data
UNRESAMPLED=NO

# Parse the arguments, see https://stackoverflow.com/a/14203146
for i in "$@"
do
case $i in
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

if [ "${OUTPUT_ARG}" != "" ]; then
    OUTPUTFILENAME="${OUTPUT_ARG}"
fi
if [ "${LOCATIONFILE_ARG}" != "" ]; then
    LOCATIONFILE="${LOCATIONFILE_ARG}"
fi
if [ "${ACCELEROMETERFILE_ARG}" != "" ]; then
    ACCELEROMETERFILE="${ACCELEROMETERFILE_ARG}"
fi

# First we have to resample the location measurements. This is needed
# because the gps posistions are tracked with a much lower frequency than
# the acceleration sensor of the smartphone:
COORDS=$(mktemp /tmp/XXXXXX)
ACCLS=$(mktemp /tmp/XXXXXX)
ACCLS2=$(mktemp /tmp/XXXXXX)
COORDS_RESAMPLED=$(mktemp /tmp/XXXXXX)
MERGED_WITH_TIME=$(mktemp /tmp/XXXXXX)
MERGED_WO_TIME=$(mktemp /tmp/XXXXXX)

# Just leave the time and acceleration in z-direction
cut $ACCELEROMETERFILE -d, -f1,4 > $ACCLS

# Leave time, latitude, longitue, speed
cut $LOCATIONFILE -d, -f1-3,5 > $COORDS

# Store header line for later usage
HEADERLOC="$(head -n1 $LOCATIONFILE)"
HEADERACC="$(head -n1 $ACCELEROMETERFILE)"

# Remove the header line from each data file
sed -i '1d;' $ACCLS
sed -i '1d;' $COORDS

gmt sample1d -s $COORDS -T${ACCLS} > $COORDS_RESAMPLED

# Remove unnecessary timestamps from acceleration file
cut $ACCLS -d, -f2 > $ACCLS2

sed -i 's/\t/, /g;' $COORDS_RESAMPLED

MERGED=$(mktemp /tmp/XXXXXX)
paste -d, $COORDS_RESAMPLED $ACCLS2 > $MERGED

# Remove lines which start with a comma after merging
sed -i '/^,/d' $MERGED

# With time is commented out currently: This file can be used later to analyze the data with a Python script
cut -d, -f1-5 $MERGED > $MERGED_WITH_TIME
sed -i '1i time, y, x, speed, z' $MERGED_WITH_TIME # Include header

cut -d, -f2,3,4,5 $MERGED > $MERGED_WO_TIME
sed -i '1i y, x, speed, z' $MERGED_WO_TIME # Include header
rm $MERGED

# Create the gpx file with acceleration data
MERGED_WO_TIME_GPX=$(mktemp /tmp/XXXXXX)
gpsbabel -t -i unicsv -f $MERGED_WO_TIME -o gpx -F $MERGED_WO_TIME_GPX

# Create the unresampled gpx file (from the original data)
if [ $UNRESAMPLED == "YES" ]; then
    COORDS_WO_TIME=$(mktemp /tmp/XXXXXX)
    cut -d, -f2,3 $COORDS > $COORDS_WO_TIME
    COORDS_WO_TIME_CONVERTED=$(mktemp /tmp/XXXXXX)
    OLDIFS=$IFS
    echo $OLDIFS
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

# Get the coordinates with the highest z values in a seperate gpx file
HIGH_Z_COORDS=$(mktemp /tmp/XXXXXX)

# Get the path of this script
SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

python "$SCRIPTPATH"/acceleration_selection.py $MERGED_WITH_TIME 5 2 $HIGH_Z_COORDS
TIME_SORTED_Z_COORDS=$(mktemp /tmp/XXXXXX)
cat $HIGH_Z_COORDS | (read -r; printf "%s\n" "$REPLY"; sort -g) | cut -d, -f2,3,4,5 > $TIME_SORTED_Z_COORDS
TIME_SORTED_Z_COORDS_GPX=$(mktemp /tmp/XXXXXX)
gpsbabel -i unicsv -f $TIME_SORTED_Z_COORDS -o gpx -F $TIME_SORTED_Z_COORDS_GPX
rm $HIGH_Z_COORDS
rm $TIME_SORTED_Z_COORDS

# Merge the last gpx into the first one and create a seperate output file
gpsbabel -i gpx -f $TIME_SORTED_Z_COORDS_GPX -i gpx -f $MERGED_WO_TIME_GPX -o gpx -F $OUTPUTFILENAME

if [ $UNRESAMPLED == "YES" ]; then
    gpsbabel -i gpx -f $TIME_SORTED_Z_COORDS_GPX -i gpx -f $COORDS_WO_TIME_CONVERTED_GPX -o gpx -F $(echo $OUTPUTFILENAME | sed 's/\(^.*\)\.gpx/\1_unresampled.gpx/g')
    rm $COORDS_WO_TIME_CONVERTED_GPX
fi

rm $ACCLS
rm $COORDS
rm $ACCLS2
rm $MERGED_WITH_TIME
rm $MERGED_WO_TIME
rm $COORDS_RESAMPLED
rm $MERGED_WO_TIME_GPX
rm $TIME_SORTED_Z_COORDS_GPX
