#!/bin/bash
set -e
set -x

# This sript takes a csv file with acceleration measurements and a csv
# file with location messurements from the android app "phybox" and
# generates a gpx file out of it in which the elevation values are actually
# the z acceleration values.

# Dependencies: GMT's "sample1d", gpsbable, basic linux commands
#               python for finding largest values

# Why is this information usefull? It can be used with a standard gpx viewer
# to see how the bike lane quality is and where problematic locations are
# "hidden" on the bike path.

# These are the output files of the phybox experiment
LOCATIONFILE="Location.csv"
ACCELEROMETERFILE="Accelerometer.csv"

#WITHTIME=false
#
#if [ $# == 1 ]; then
#    WITHTIME=true
#fi

# First we have to resample the location measurements. This is needed
# because the gps posistion is tracked with a much lower frequency than
# the acceleration of the smartphone:
COORDS=$(mktemp /tmp/location.XXXXXX)
ACCLS=$(mktemp /tmp/acceleration.XXXXXX)
ACCLS2=$(mktemp /tmp/acceleration2.XXXXXX)
COORDS_RESAMPLED=$(mktemp /tmp/location_resampled.XXXXXX)
MERGED=$(mktemp /tmp/merged_accel_and_locs.XXXXXX)
MERGED2=$(mktemp /tmp/merged_accel_and_locs2.XXXXXX)

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

paste -d, $COORDS_RESAMPLED $ACCLS2 > $MERGED

# Remove lines which start with a comma after merging
sed -i '/^,/d' $MERGED

# With time is commented out currently: This file can be used later to analyze the data with a Python script
cut -d, -f1-5 $MERGED > $MERGED2
sed -i '1i time, y, x, speed, z' $MERGED2 # Include header
mv $MERGED2 ./xyz_data_with_time.csv

cut -d, -f2,3,4,5 $MERGED > $MERGED2
sed -i '1i y, x, speed, z' $MERGED2 # Include header

gpsbabel -t -i unicsv -f $MERGED2 -o gpx -F xyz_data.gpx


#  <wpt lat="49.989805" lon="8.675115">
#      <time>2020-08-19T12:14:22Z</time>
#      <name>First</name>
#      <cmt>comment</cmt>
#      <desc>description</desc>
#  </wpt>

      
rm $ACCLS
rm $COORDS
rm $ACCLS2
rm $MERGED
rm $MERGED2
rm $COORDS_RESAMPLED
