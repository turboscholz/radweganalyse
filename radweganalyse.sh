#!/bin/sh
set -e
trap cleanup SIGINT SIGTERM ERR EXIT

usage() {
  cat <<EOF
This sript takes a csv file with acceleration measurements and a csv
file with location messurements from the Android app "phyphox" and
generates a gpx file out of it in which the elevation values are actually
the z acceleration values.

Why is this information usefull? It can be used with a standard gpx viewer
to see how good or bad the bike lane quality is and where problematic
locations are "hidden" on the bike path.

Dependencies: GMT's "sample1d", gpsbable, basic linux commands
              python3 for finding largest values, pandas python package

-h, --help            Print this help and exit
-v, --verbose         Print script debug info
-o, --output          The output file name can be overridden, default is "xyz_data.gpx"
-l, --locations       This is the input file of the phyphox experiment, default is "Location.csv"
-a, --accelerations   This is the acceleration measurement file from phyphox, default "Accelerometer.csv" or "Linear Acceleration.csv"
-m, --max             The number of gps positions this script should find where the acceleration in z direction is exceptional, default 5
    --maxonly         Only create a gpx file pointing to positions with maximum z-acceleration
    --no-analysis     No analysis of the data via python script, only create a gpx file. Cannot be set with "maxonly" at the same time.
-s, --start           The time in seconds in the measured data at which the analysis should start, default 0
-f, --offset          The time offset in seconds after start when the analysis should end, default 0 (i.e. no time offset)
-w, --window          The time window in seconds in which no other value with high z accelerations will be searched, default 2
-t, --test            Start a test session to check if all functions and dependencies work as expected
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

check_dependencies() {
  command -v gmt >&2 > /dev/null || command -v GMT >&2 > /dev/null || die "gmt binary not found. In Ubuntu, install with \"sudo apt-get install gmt\"."
  command -v gpsbabel >&2 > /dev/null || die "gpsbabel binary not found. In Ubuntu, install with \"sudo apt-get install gpsbabel\"."
  command -v awk      >&2 > /dev/null || die "awk binary not found. In Ubuntu, install with \"sudo apt-get install mawk\"."
  command -v sed      >&2 > /dev/null || die "sed binary not found"

  # Get the path of this script
  SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

  # Find the gps coordinates where the highest z acceleration values happened
  MAXZCALCSCRIPTFOUND="YES"
  if [ ! -f "$SCRIPTPATH"/acceleration_selection.py ]; then
    msg "${RED}acceleration_selection.py not found, max z positions cannot be calulated${NOFORMAT}"
    MAXZCALCSCRIPTFOUND="NO"
  fi
}

# This function is needed to find out which version of gmt is installed.
# The programm expects different arguments depending on the available version.
set_gmt_binary()
{
    GMTVERSION=""
    if [ "$(command -v gmt 2>&1)" != "" ] && [ "$(gmt --version | cut -d. -f 1 )" -eq 5 ]; then
        GMTVERSION="5"
    fi
    if [ "$(command -v gmt 2>&1)" != "" ] && [ "$(gmt --version | cut -d. -f 1 )" -ge 6 ]; then
        GMTVERSION="6"
    fi
    if [ "$GMTVERSION" == "" ]; then
        GMTVERSION="$(GMT --version 2>&1 | head -1 | sed 's/GMT Version //g' | cut -d. -f 1)"
    fi
    if [ "$GMTVERSION" == "" ]; then
        die "Unknown gmt version installed!"
    fi
}

setup_test_vars()
{
    ACCSTESTFILE=$(mktemp /tmp/XXXXXX --dry-run)
    COORDSTESTFILE=$(mktemp /tmp/XXXXXX --dry-run)
}

check_for_python3()
{
    ISPYTHON3HERE="YES"
    set +e
    command -v python3 2>&1 >> /dev/null
    retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        ISPYTHON3HERE="NO"
        msg "${YELLOW}Warning:${NOFORMAT} python3 not found - no data analysis possible. In Ubuntu, install with \"sudo apt-get install python\"."
    fi
}

parse_params() {
  # default values of variables set from params
  CSVFORMAT="0"
  OUTPUT_ARG="xyz_data.gpx"
  LOCATIONFILE="Location.csv"
  ACCELEROMETERFILE_WITHG="Accelerometer.csv"
  ACCELEROMETERFILE_WITHOUTG="Linear Acceleration.csv"
  BAD_STREET_POSITIONS_ARG="5"
  TIME_WINDOW_ARG="2"
  OFFSET_ARG=0
  MAXONLY=NO
  ANALYSIS=YES
  TEST=NO
  START=0
  OFFSET=0

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    -o | --output)
      OUTPUT_ARG="${2-}"
      shift
      ;;
    -l | --locations)
      LOCATIONFILE_ARG="${2-}"
      shift
      ;;
    -a | --accelerations)
      ACCELEROMETERFILE_ARG="${2-}"
      shift
      ;;
    -m | --max)
      BAD_STREET_POSITIONS_ARG="${2-}"
      shift
      ;;
    -w | --window)
      TIME_WINDOW_ARG="${2-}"
      shift
      ;;
    -s | --start)
      START_ARG="${2-}"
      shift
      ;;
    -f | --offset)
      OFFSET_ARG="${2-}"
      shift
      ;;
    --maxonly)
      MAXONLY=YES ;;
    --no-analysis)
      ANALYSIS=NO ;;
    -t | --test)
      TEST=YES ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  return 0
}

validate_input()
{
    # Assign values of script arguments
    if [ "$ANALYSIS" == "NO" ] && [ "$MAXONLY" == "YES" ]; then
        msg "${RED}Error:${NOFORMAT} --maxonly and --no-analysis cannot be set at the same time."
        die
    fi
}

setup_input_vars()
{
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
    if [ "${START_ARG}" != "" ]; then
        START="${START_ARG}"
    fi
    if [ "${OFFSET_ARG}" != "" ]; then
        OFFSET="${OFFSET_ARG}"
    fi

    # Detect which acceleration file is available, set GVALUE accordingly
    GVALUE="0.0"
    if [ "$TEST" == "NO" ] && [ "$ACCELEROMETERFILE" == "" ] ; then
        if [ -f "$ACCELEROMETERFILE_WITHG" ]; then
            ACCELEROMETERFILE="$ACCELEROMETERFILE_WITHG"
            GVALUE="9.81"
        elif [ -f "$ACCELEROMETERFILE_WITHOUTG" ]; then
            ACCELEROMETERFILE="$ACCELEROMETERFILE_WITHOUTG"
        else
            die "Please provide an Acceleration input file via -a option"
        fi
    elif [ "$TEST" == "NO" ] && [ ! -f "$ACCELEROMETERFILE" ]; then
        die "Acceleration input file \"$ACCELEROMETERFILE\" not found - aborting"
    fi
}

################################################################################
############################## CLEANUP SECTION #################################
################################################################################

cleanup_tests()
{
    msg "Cleanup test files ..."

    rm $ACCSTESTFILE
    rm $COORDSTESTFILE

    msg "Done."
}

cleanup() {
    trap - SIGINT SIGTERM ERR EXIT

    if [ "$TEST" == "YES" ]; then
    	cleanup_tests
    fi
}

################################################################################
############################### TEST SECTION ###################################
################################################################################

output_actual_vs_expected()
{
    msg "Actual value: ${1}, Expected: ${2}"
    echo
}

write_files_test()
{
    lines=$(wc -l $ACCSTESTFILE | cut -d " " -f 1)
    if [ $lines -ne 4 ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "Lines of accelerations file ${ACCSTESTFILE}:"
        output_actual_vs_expected $lines 4
        return 1
    fi

    lines=$(wc -l $COORDSTESTFILE | cut -d " " -f 1)
    if [ $lines -ne 3 ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "Lines of coordinations file ${COORDSTESTFILE}:"
        output_actual_vs_expected $lines 3
        return 1
    fi

    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

convert_data_test()
{
    TABDECIFILE=$(mktemp /tmp/XXXXXX --dry-run)
    cat <<EOF > $TABDECIFILE
"Time (s)"	"Linear Acceleration x (m/s^2)"	"Linear Acceleration y (m/s^2)"	"Linear Acceleration z (m/s^2)"
3.822818600E-2	1.573801041E-2	-1.144409180E-2	1.094026566E-1
4.323306900E-2	4.181289673E-2	-2.140426636E-2	1.027250290E-1
4.826846900E-2	8.366203308E-2	-7.002162933E-2	1.464896202E-1
EOF
    SEMIDECIFILE=$(mktemp /tmp/XXXXXX --dry-run)
    cat <<EOF > $SEMIDECIFILE
"Time (s)";"Linear Acceleration x (m/s^2)";"Linear Acceleration y (m/s^2)";"Linear Acceleration z (m/s^2)"
3.822818600E-2;1.573801041E-2;-1.144409180E-2;1.094026566E-1
4.323306900E-2;4.181289673E-2;-2.140426636E-2;1.027250290E-1
4.826846900E-2;8.366203308E-2;-7.002162933E-2;1.464896202E-1
EOF
    TABCOMMAFILE=$(mktemp /tmp/XXXXXX --dry-run)
    cat <<EOF > $TABCOMMAFILE
"Time (s)"	"Linear Acceleration x (m/s^2)"	"Linear Acceleration y (m/s^2)"	"Linear Acceleration z (m/s^2)"
3,822818600E-2	1,573801041E-2	-1,144409180E-2	1,094026566E-1
4,323306900E-2	4,181289673E-2	-2,140426636E-2	1,027250290E-1
4,826846900E-2	8,366203308E-2	-7,002162933E-2	1,464896202E-1
EOF
    SEMICOMMAFILE=$(mktemp /tmp/XXXXXX --dry-run)
    cat <<EOF > $SEMICOMMAFILE
"Time (s)";"Linear Acceleration x (m/s^2)";"Linear Acceleration y (m/s^2)";"Linear Acceleration z (m/s^2)"
3,822818600E-2;1,573801041E-2;-1,144409180E-2;1,094026566E-1
4,323306900E-2;4,181289673E-2;-2,140426636E-2;1,027250290E-1
4,826846900E-2;8,366203308E-2;-7,002162933E-2;1,464896202E-1
EOF

    EXPECTED_FILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $EXPECTED_FILE
"Time (s)","Linear Acceleration x (m/s^2)","Linear Acceleration y (m/s^2)","Linear Acceleration z (m/s^2)"
3.822818600E-2,1.573801041E-2,-1.144409180E-2,1.094026566E-1
4.323306900E-2,4.181289673E-2,-2.140426636E-2,1.027250290E-1
4.826846900E-2,8.366203308E-2,-7.002162933E-2,1.464896202E-1
EOF

    # 1) Tabulator, decimal point
    INPUTFORMAT=1
    CONVERTEDFILE=$(convert_data "$INPUTFORMAT" "$TABDECIFILE")
    set +e
    cmp --silent $EXPECTED_FILE $CONVERTEDFILE
    retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        msg "${FUNCNAME[0]} (FORMAT: $INPUTFORMAT): ${RED}failed${NOFORMAT}"
        msg "expected:"
        cat $EXPECTED_FILE
        msg "got:"
        cat $CONVERTEDFILE
        rm $CONVERTEDFILE
        rm $EXPECTED_FILE
        rm $TABDECIFILE
        return 1
    fi
    rm $CONVERTEDFILE

    # 2) Semicolon, decimal point
    INPUTFORMAT=2
    CONVERTEDFILE=$(convert_data "$INPUTFORMAT" "$SEMIDECIFILE")
    set +e
    cmp --silent $EXPECTED_FILE $CONVERTEDFILE
    retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        msg "${FUNCNAME[0]} (FORMAT: $INPUTFORMAT): ${RED}failed${NOFORMAT}"
        msg "expected:"
        cat $EXPECTED_FILE
        msg "got:"
        cat $CONVERTEDFILE
        rm $CONVERTEDFILE
        rm $EXPECTED_FILE
        rm $SEMIDECIFILE
        return 1
    fi
    rm $CONVERTEDFILE

    # 3) Tabulator, decimal comma
    INPUTFORMAT=3
    CONVERTEDFILE=$(convert_data "$INPUTFORMAT" "$TABCOMMAFILE")
    set +e
    cmp --silent $EXPECTED_FILE $CONVERTEDFILE
    retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        msg "${FUNCNAME[0]} (FORMAT: $INPUTFORMAT): ${RED}failed${NOFORMAT}"
        msg "expected:"
        cat $EXPECTED_FILE
        msg "got:"
        cat $CONVERTEDFILE
        rm $CONVERTEDFILE
        rm $EXPECTED_FILE
        rm $TABCOMMAFILE
        return 1
    fi
    rm $CONVERTEDFILE

    # 4) Semicolon, decimal comma
    INPUTFORMAT=4
    CONVERTEDFILE=$(convert_data "$INPUTFORMAT" "$SEMICOMMAFILE")
    set +e
    cmp --silent $EXPECTED_FILE $CONVERTEDFILE
    retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        msg "${FUNCNAME[0]} (FORMAT: $INPUTFORMAT): ${RED}failed${NOFORMAT}"
        msg "expected:"
        cat $EXPECTED_FILE
        msg "got:"
        cat $CONVERTEDFILE
        rm $CONVERTEDFILE
        rm $EXPECTED_FILE
        rm $SEMICOMMAFILE
        return 1
    fi
    rm $CONVERTEDFILE

    rm $SEMICOMMAFILE
    rm $SEMIDECIFILE
    rm $TABCOMMAFILE
    rm $TABDECIFILE

    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

remove_duplicates_test()
{
    DOUBLEROWFILE=$(mktemp /tmp/XXXXXX --dry-run)
    cat <<EOF > $DOUBLEROWFILE
"Time (s)"	"Linear Acceleration x (m/s^2)"	"Linear Acceleration y (m/s^2)"	"Linear Acceleration z (m/s^2)"
3.822818600E-2	1.573801041E-2	-1.144409180E-2	1.094026566E-1
3.822818600E-2	1.573801041E-2	-1.144409180E-2	1.094026566E-1
4.323306900E-2	4.181289673E-2	-2.140426636E-2	1.027250290E-1
EOF

    EXPECTED_FILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $EXPECTED_FILE
"Time (s)"	"Linear Acceleration x (m/s^2)"	"Linear Acceleration y (m/s^2)"	"Linear Acceleration z (m/s^2)"
3.822818600E-2	1.573801041E-2	-1.144409180E-2	1.094026566E-1
4.323306900E-2	4.181289673E-2	-2.140426636E-2	1.027250290E-1
EOF

    set -e
    CONVERTEDFILE=$(remove_duplicates "$DOUBLEROWFILE")
    set +e
    cmp --silent $EXPECTED_FILE $CONVERTEDFILE
    retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        msg "${FUNCNAME[0]} (FORMAT: $INPUTFORMAT): ${RED}failed${NOFORMAT}"
        msg "expected:"
        cat $EXPECTED_FILE
        msg "got:"
        cat $CONVERTEDFILE
        rm $CONVERTEDFILE
        rm $EXPECTED_FILE
        return 1
    fi
    rm $CONVERTEDFILE
    rm $DOUBLEROWFILE

    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

export_times_and_zaccs_in_file_test()
{
    ACCLS=$(export_times_and_zaccs_in_file "$ACCSTESTFILE")
    EXPECTED_FILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $EXPECTED_FILE
0.000000000E0,1.000000000E-1
5.000000000E-1,2.000000000E-1
1.000000000E0,3.000000000E-1
EOF
    set +e
    cmp --silent $EXPECTED_FILE $ACCLS
    retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "expected:"
        cat $EXPECTED_FILE
        msg "got:"
        cat $ACCLS
        rm $ACCLS
        rm $EXPECTED_FILE
        return 1
    fi
    rm $ACCLS
    rm $EXPECTED_FILE
    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

export_time_lat_long_speed_test()
{
    TMPINPUTFILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $TMPINPUTFILE
"Time (s)","Latitude (°)","Longitude (°)","Height (m)","Velocity (m/s)","Direction (°)","Horizontal Accuracy (m)","Vertical Accuracy (m)"
0.000000000E0,4.000000000E1,5.000000000E0,1.200000000E2,1.000000000E0,0.000000000E0,1.000000000E1,1.000000000E1
5.000000000E-1,4.500000000E1,5.500000000E0,1.200000000E2,1.500000000E0,0.000000000E0,1.000000000E1,1.000000000E1
1.000000000E0,5.000000000E1,6.000000000E0,1.200000000E2,2.000000000E0,0.000000000E0,1.000000000E1,1.000000000E1
EOF
    COORDS=$(export_time_lat_long_speed 0 0 "$TMPINPUTFILE")
    EXPECTED_FILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $EXPECTED_FILE
0.000000000E0,4.000000000E1,5.000000000E0,1.000000000E0
5.000000000E-1,4.500000000E1,5.500000000E0,1.500000000E0
1.000000000E0,5.000000000E1,6.000000000E0,2.000000000E0
EOF
    set +e
    cmp --silent $EXPECTED_FILE $COORDS
    retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "expected:"
        cat $EXPECTED_FILE
        msg "got:"
        cat $COORDS
        rm $COORDS
        rm $EXPECTED_FILE
        rm $TMPINPUTFILE
        return 1
    fi
    rm $COORDS
    rm $EXPECTED_FILE
    rm $TMPINPUTFILE
    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

export_time_lat_long_speed_with_starttime_test()
{
    TMPINPUTFILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $TMPINPUTFILE
"Time (s)","Latitude (°)","Longitude (°)","Height (m)","Velocity (m/s)","Direction (°)","Horizontal Accuracy (m)","Vertical Accuracy (m)"
0.000000000E0,4.000000000E1,5.000000000E0,1.200000000E2,1.000000000E0,0.000000000E0,1.000000000E1,1.000000000E1
5.000000000E-1,4.500000000E1,5.500000000E0,1.200000000E2,1.500000000E0,0.000000000E0,1.000000000E1,1.000000000E1
1.000000000E0,5.000000000E1,6.000000000E0,1.200000000E2,2.000000000E0,0.000000000E0,1.000000000E1,1.000000000E1
EOF
    COORDS=$(export_time_lat_long_speed 0.7 0 "$TMPINPUTFILE")
    EXPECTED_FILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $EXPECTED_FILE
1.000000000E0,5.000000000E1,6.000000000E0,2.000000000E0
EOF
    set +e
    cmp --silent $EXPECTED_FILE $COORDS
    retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "expected:"
        cat $EXPECTED_FILE
        msg "got:"
        cat $COORDS
        rm $COORDS
        rm $EXPECTED_FILE
        rm $TMPINPUTFILE
        return 1
    fi
    rm $COORDS
    rm $EXPECTED_FILE
    rm $TMPINPUTFILE
    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

export_time_lat_long_speed_with_offset_test()
{
    # When OFFSET is not 0, the function export_time_lat_long_speed() should
    # use the offset parameter for setting the upper limit of the time in the location input.
    # This test will test the behaviour.
    OFFSET=1
    TMPINPUTFILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $TMPINPUTFILE
"Time (s)","Latitude (°)","Longitude (°)","Height (m)","Velocity (m/s)","Direction (°)","Horizontal Accuracy (m)","Vertical Accuracy (m)"
0.000000000E0,4.000000000E1,5.000000000E0,1.200000000E2,1.000000000E0,0.000000000E0,1.000000000E1,1.000000000E1
5.000000000E-1,4.500000000E1,5.500000000E0,1.200000000E2,1.500000000E0,0.000000000E0,1.000000000E1,1.000000000E1
1.000000000E0,5.000000000E1,6.000000000E0,1.200000000E2,2.000000000E0,0.000000000E0,1.000000000E1,1.000000000E1
1.500000000E0,6.000000000E1,7.000000000E0,1.200000000E2,3.000000000E0,0.000000000E0,1.000000000E1,1.000000000E1
2.000000000E0,7.000000000E1,8.000000000E0,1.200000000E2,4.000000000E0,0.000000000E0,1.000000000E1,1.000000000E1
3.000000000E0,8.000000000E1,9.000000000E0,1.200000000E2,5.000000000E0,0.000000000E0,1.000000000E1,1.000000000E1
EOF
    COORDS=$(export_time_lat_long_speed 0.5 1 "$TMPINPUTFILE")
    EXPECTED_FILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $EXPECTED_FILE
5.000000000E-1,4.500000000E1,5.500000000E0,1.500000000E0
1.000000000E0,5.000000000E1,6.000000000E0,2.000000000E0
1.500000000E0,6.000000000E1,7.000000000E0,3.000000000E0
EOF
    set +e
    cmp --silent $EXPECTED_FILE $COORDS
    retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "expected:"
        cat $EXPECTED_FILE
        msg "got:"
        cat $COORDS
        rm $COORDS
        rm $EXPECTED_FILE
        rm $TMPINPUTFILE
        return 1
    fi
    rm $COORDS
    rm $EXPECTED_FILE
    rm $TMPINPUTFILE
    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

generate_resampled_coords_file_test(){
    COORDSFILETMP=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $COORDSFILETMP
0.000000000E0,4.000000000E1,5.000000000E0,1.000000000E0
1.000000000E0,5.000000000E1,6.000000000E0,2.000000000E0
EOF
    ZACCLSFILETMP=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $ZACCLSFILETMP
0.000000000E0,1.000000000E-1
5.000000000E-1,2.000000000E-1
1.000000000E0,3.000000000E-1
EOF

    RESAMPLED_COORDS_FILE=$(generate_resampled_coords_file $COORDSFILETMP $ZACCLSFILETMP)

    EXPECTED_FILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $EXPECTED_FILE
0	40	5	1
0.5	45	5.5	1.5
1	50	6	2
EOF
    set +e
    cmp --silent $EXPECTED_FILE $RESAMPLED_COORDS_FILE
    retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "expected:"
        cat $EXPECTED_FILE
        msg "got:"
        cat $RESAMPLED_COORDS_FILE
        rm $RESAMPLED_COORDS_FILE
        rm $EXPECTED_FILE
        rm $COORDSFILETMP
        rm $ZACCLSFILETMP
        return 1
    fi
    rm $RESAMPLED_COORDS_FILE
    rm $EXPECTED_FILE
    rm $COORDSFILETMP
    rm $ZACCLSFILETMP
    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

merge_coords_and_zacc_file_test()
{
    ZACCLSFILETMP=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $ZACCLSFILETMP
0	1.000000000E-1
0.5	2.000000000E-1
1	3.000000000E-1
5	4.000000000E-1
10	5.000000000E-1
EOF

    RESAMPLED_COORDS_FILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $RESAMPLED_COORDS_FILE
0	40	5	1
0.5	45	5.5	1.5
1	50	6	2
5	55	6.5	2.5
10	60	7	3
EOF

    MERGEDTESTFILE=$(merge_coords_and_zacc_file $RESAMPLED_COORDS_FILE $ZACCLSFILETMP)

    rm $ZACCLSFILETMP $RESAMPLED_COORDS_FILE

    EXPECTED_FILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $EXPECTED_FILE
0,40,5,1,1.000000000E-1
0.5,45,5.5,1.5,2.000000000E-1
1,50,6,2,3.000000000E-1
5,55,6.5,2.5,4.000000000E-1
10,60,7,3,5.000000000E-1
EOF
    set +e
    cmp --silent $EXPECTED_FILE $MERGEDTESTFILE
    retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "expected:"
        cat $EXPECTED_FILE
        msg "got:"
        cat $MERGEDTESTFILE
        rm $MERGEDTESTFILE
        rm $EXPECTED_FILE
        return 1
    fi
    rm $MERGEDTESTFILE
    rm $EXPECTED_FILE
    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

create_gpx_with_track_file_test()
{
    INPUTFILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $INPUTFILE
y, x, speed, z
40,5,1,1.000000000E-1
EOF

    GPXFILE=$(mktemp /tmp/XXXXXX)
    gpsbabel -t -i unicsv -f $INPUTFILE -o gpx -F $GPXFILE
    sed -i -e 3d $GPXFILE #We need this hack to remove the current timestamp in the third line
    sed -i $GPXFILE -re '1,2d' #Remove lines 1 and 2 in the Output-GPX file (this is just a header)

    EXPECTED_FILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $EXPECTED_FILE
  <bounds minlat="40.000000000" minlon="5.000000000" maxlat="40.000000000" maxlon="5.000000000"/>
  <trk>
    <trkseg>
      <trkpt lat="40.000000000" lon="5.000000000">
        <ele>0.100</ele>
        <speed>1.000000</speed>
      </trkpt>
    </trkseg>
  </trk>
</gpx>
EOF
    set +e
    cmp --silent $EXPECTED_FILE $GPXFILE
    retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "expected:"
        cat $EXPECTED_FILE
        msg "got:"
        cat $GPXFILE
        rm $GPXFILE
        rm $EXPECTED_FILE
        rm $INPUTFILE
        return 1
    fi
    rm $GPXFILE
    rm $EXPECTED_FILE
    rm $INPUTFILE
    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

create_gpx_without_track_file_test()
{
    INPUTFILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $INPUTFILE
y, x, speed, z
40,5,1,1.000000000E-1
EOF

    GPXFILE=$(mktemp /tmp/XXXXXX)
    gpsbabel -i unicsv -f $INPUTFILE -o gpx -F $GPXFILE
    sed -i -e 3d $GPXFILE #We need this hack to remove the current timestamp in the third line
    sed -i $GPXFILE -re '1,2d' #Remove lines 1 and 2 in the Output-GPX file (this is just a header)

    EXPECTED_FILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $EXPECTED_FILE
  <bounds minlat="40.000000000" minlon="5.000000000" maxlat="40.000000000" maxlon="5.000000000"/>
  <wpt lat="40.000000000" lon="5.000000000">
    <ele>0.100</ele>
    <name>WPT001</name>
    <cmt>WPT001</cmt>
    <desc>WPT001</desc>
  </wpt>
</gpx>
EOF
    set +e
    cmp --silent $EXPECTED_FILE $GPXFILE
    retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "expected:"
        cat $EXPECTED_FILE
        msg "got:"
        cat $GPXFILE
        rm $GPXFILE
        rm $EXPECTED_FILE
        rm $INPUTFILE
        return 1
    fi
    rm $GPXFILE
    rm $EXPECTED_FILE
    rm $INPUTFILE
    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

create_coords_only_gpx_file_test()
{
    COORDS=$(export_time_lat_long_speed 0 0 "$COORDSTESTFILE")
    GPXFILE=$(create_coords_only_gpx_file $COORDS)
    sed -i -e 3d $GPXFILE #We need this hack to remove the current timestamp in the third line
    sed -i $GPXFILE -re '1,2d' #Remove lines 1 and 2 in the Output-GPX file (this is just a header)

    EXPECTED_FILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $EXPECTED_FILE
  <bounds minlat="40.000000000" minlon="5.000000000" maxlat="50.000000000" maxlon="6.000000000"/>
  <trk>
    <trkseg>
      <trkpt lat="40.000000000" lon="5.000000000"/>
      <trkpt lat="50.000000000" lon="6.000000000"/>
    </trkseg>
  </trk>
</gpx>
EOF
    set +e
    cmp --silent $EXPECTED_FILE $GPXFILE
    retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "expected:"
        cat $EXPECTED_FILE
        msg "got:"
        cat $GPXFILE
        rm $GPXFILE
        rm $EXPECTED_FILE
        rm $COORDS
        return 1
    fi
    rm $GPXFILE
    rm $EXPECTED_FILE
    rm $COORDS
    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

analyze_data_via_script_test()
{
    if [ "$ISPYTHON3HERE" == "NO" ]; then
        return 0
    fi
    if [ $MAXZCALCSCRIPTFOUND == "NO" ]; then
        msg "${FUNCNAME[0]}: ${YELLOW}ignored${NOFORMAT} - External analysis script not found"
        return 0
    fi

    TMPINPUTFILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $TMPINPUTFILE
time, y, x, speed, z
5.0,49.0,8.6,6.9,58.7
EOF
    TMPOUTFILE=$(mktemp /tmp/XXXXXX)
    analyze_data_via_script $TMPINPUTFILE 1 1 $TMPOUTFILE

    EXPECTED_FILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $EXPECTED_FILE
time,y,x,speed,z
5.0,49.0,8.6,6.9,58.7
EOF
    set +e
    cmp --silent $EXPECTED_FILE $TMPOUTFILE
    retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "expected:"
        cat $EXPECTED_FILE
        msg "got:"
        cat $TMPOUTFILE
        rm $TMPOUTFILE
        rm $EXPECTED_FILE
        rm $TMPINPUTFILE
        return 1
    fi
    rm $TMPOUTFILE
    rm $EXPECTED_FILE
    rm $TMPINPUTFILE
    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

sort_for_and_remove_time_column_test()
{
    TMPINPUTFILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $TMPINPUTFILE
time, y, x, speed, z
5.0,30.0,5,6,7
1.0,20.0,5,6,7
EOF
    TMPOUTFILE=$(sort_for_and_remove_time_column $TMPINPUTFILE)

    EXPECTED_FILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $EXPECTED_FILE
 y, x, speed, z
20.0,5,6,7
30.0,5,6,7
EOF
    set +e
    cmp --silent $EXPECTED_FILE $TMPOUTFILE
    retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "expected:"
        cat $EXPECTED_FILE
        msg "got:"
        cat $TMPOUTFILE
        rm $TMPOUTFILE
        rm $EXPECTED_FILE
        rm $TMPINPUTFILE
        return 1
    fi
    rm $TMPOUTFILE
    rm $EXPECTED_FILE
    rm $TMPINPUTFILE
    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

correct_zaccs_for_gvalue_test()
{
    GVALUE=9.81
    INPUT_FILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $INPUT_FILE
0.000000000E0	1.000000000E-1
1.000000000E0	0.000000000E0
EOF
    EXPECTED_FILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $EXPECTED_FILE
0.000000000	-9.710000000
1.000000000	-9.810000000
EOF

    COOR_FILE=$(correct_zaccs_for_gvalue $GVALUE $INPUT_FILE)

    set +e
    cmp --silent $EXPECTED_FILE $COOR_FILE
    retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "expected:"
        cat $EXPECTED_FILE
        msg "got:"
        cat $COOR_FILE
        rm $COOR_FILE
        rm $EXPECTED_FILE
        return 1
    fi
    rm $COOR_FILE
    rm $EXPECTED_FILE
    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

detect_format_comma_decimal_point_test()
{
    #0: Comma, decimal point
    EXPECTEDCSVFORMAT=0
    ACCLSFILETMP=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $ACCLSFILETMP
"Time (s)","Acceleration x (m/s^2)","Acceleration y (m/s^2)","Acceleration z (m/s^2)"
0.000000000E0,3.555450439E-1,3.094482422E-1,1.006282043E1
EOF

    FORMAT=$(detect_format $ACCLSFILETMP)
    rm $ACCLSFILETMP
    if [ $FORMAT -ne $EXPECTEDCSVFORMAT ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "expected: $EXPECTEDCSVFORMAT"
        msg "got:      $FORMAT"
        return 1
    fi
    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

detect_format_tabulator_decimal_point_test()
{
    #3: Tabulator, decimal comma
    EXPECTEDCSVFORMAT=1
    ACCLSFILETMP=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $ACCLSFILETMP
"Time (s)"	"Acceleration x (m/s^2)"	"Acceleration y (m/s^2)"	"Acceleration z (m/s^2)"
0.000000000E0	3.555450439E-1	3.094482422E-1	1.006282043E1
EOF

    FORMAT=$(detect_format $ACCLSFILETMP)
    rm $ACCLSFILETMP
    if [ $FORMAT -ne $EXPECTEDCSVFORMAT ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "expected: $EXPECTEDCSVFORMAT"
        msg "got: $FORMAT"
        return 1
    fi
    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

detect_format_semicolon_decimal_point_test()
{
    #2: Semicolon, decimal point
    EXPECTEDCSVFORMAT=2
    ACCLSFILETMP=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $ACCLSFILETMP
"Time (s)";"Acceleration x (m/s^2)";"Acceleration y (m/s^2)";"Acceleration z (m/s^2)"
0.000000000E0;3.555450439E-1;3.094482422E-1;1.006282043E1
EOF

    FORMAT=$(detect_format $ACCLSFILETMP)
    rm $ACCLSFILETMP
    if [ $FORMAT -ne $EXPECTEDCSVFORMAT ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "expected: $EXPECTEDCSVFORMAT"
        msg "got: $FORMAT"
        return 1
    fi
    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

detect_format_tabulator_decimal_comma_test()
{
    #1: Tabulator, decimal point
    EXPECTEDCSVFORMAT=3
    ACCLSFILETMP=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $ACCLSFILETMP
"Time (s)"	"Acceleration x (m/s^2)"	"Acceleration y (m/s^2)"	"Acceleration z (m/s^2)"
0,000000000E0	3,555450439E-1	3,094482422E-1	1,006282043E1
EOF

    FORMAT=$(detect_format $ACCLSFILETMP)
    rm $ACCLSFILETMP
    if [ $FORMAT -ne $EXPECTEDCSVFORMAT ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "expected: $EXPECTEDCSVFORMAT"
        msg "got:      $FORMAT"
        return 1
    fi
    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

detect_format_semicolon_decimal_comma_test()
{
    #4: Semicolon, decimal comma
    EXPECTEDCSVFORMAT=4
    ACCLSFILETMP=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $ACCLSFILETMP
"Time (s)";"Acceleration x (m/s^2)";"Acceleration y (m/s^2)";"Acceleration z (m/s^2)"
0,000000000E0;3,555450439E-1;3,094482422E-1;1,006282043E1
EOF

    FORMAT=$(detect_format $ACCLSFILETMP)
    rm $ACCLSFILETMP
    if [ $FORMAT -ne $EXPECTEDCSVFORMAT ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "expected: $EXPECTEDCSVFORMAT"
        msg "got: $FORMAT"
        return 1
    fi
    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

do_regression_tests()
{
    cat <<EOF > $ACCSTESTFILE
"Time (s)","Linear Acceleration x (m/s^2)","Linear Acceleration y (m/s^2)","Linear Acceleration z (m/s^2)"
0.000000000E0,1.000000000E-1,2.000000000E-1,1.000000000E-1
5.000000000E-1,1.000000000E-1,2.000000000E-1,2.000000000E-1
1.000000000E0,1.000000000E-1,2.000000000E-1,3.000000000E-1
EOF

    cat <<EOF > $COORDSTESTFILE
"Time (s)","Latitude (°)","Longitude (°)","Height (m)","Velocity (m/s)","Direction (°)","Horizontal Accuracy (m)","Vertical Accuracy (m)"
0.000000000E0,4.000000000E1,5.000000000E0,1.200000000E2,1.000000000E0,0.000000000E0,1.000000000E1,1.000000000E1
1.000000000E0,5.000000000E1,6.000000000E0,1.200000000E2,2.000000000E0,0.000000000E0,1.000000000E1,1.000000000E1
EOF

    write_files_test
    remove_duplicates_test
    detect_format_comma_decimal_point_test
    detect_format_tabulator_decimal_point_test
    detect_format_semicolon_decimal_point_test
    detect_format_tabulator_decimal_comma_test
    detect_format_semicolon_decimal_comma_test
    convert_data_test
    export_times_and_zaccs_in_file_test
    correct_zaccs_for_gvalue_test
    export_time_lat_long_speed_test
    export_time_lat_long_speed_with_starttime_test
    export_time_lat_long_speed_with_offset_test
    generate_resampled_coords_file_test
    merge_coords_and_zacc_file_test
    create_gpx_with_track_file_test
    create_gpx_without_track_file_test
    create_coords_only_gpx_file_test
    analyze_data_via_script_test
    sort_for_and_remove_time_column_test
    echo
}

################################################################################
################### BELOW THIS LINE THE ACTUAL LOGIC HAPPENS ###################
################################################################################

remove_duplicates()
{
    INPUT="$1"
    TMPFILE=$(mktemp /tmp/XXXXXX)
    cat "$INPUT" | uniq > $TMPFILE
    echo "$TMPFILE"
}

#Convert input data into standard format using comma and decimal point
convert_data()
{
    INPUTFMT="$1"
    INPUT="$2"
    TMPFILE=$(mktemp /tmp/XXXXXX)

    case "$INPUTFMT" in
        #Comma, decimal point, nothing to reformat
        0) cp "$INPUT" $TMPFILE ;;
        #Tabulator, decimal point
        1) sed 's/\t/,/g' "$INPUT" > $TMPFILE ;;
        #Semicolon, decimal point
        2) sed 's/;/,/g' "$INPUT" > $TMPFILE ;;
        #Tabulator, decimal comma
        3) sed 's/,/./g; s/\t/,/g' "$INPUT" > $TMPFILE ;;
        #Semicolon, decimal comma
        4) sed 's/,/./g; s/;/,/g' "$INPUT" > $TMPFILE ;;
        *) die "Unknown input CSV data format" ;;
    esac

    echo "$TMPFILE"
}

# Just leave the time and acceleration in z-direction
export_times_and_zaccs_in_file()
{
    INPUT="$1"
    TMPFILE=$(mktemp /tmp/XXXXXX)
    cut "$INPUT" -d, -f1,4 > $TMPFILE
    sed -i '1d;' $TMPFILE
    echo "$TMPFILE"
}

# Leave time, latitude, longitue, speed
export_time_lat_long_speed ()
{
    STARTTIME="$1"
    OFFSET_SEC="$2"
    INPUT="$3"
    TMPFILE=$(mktemp /tmp/XXXXXX)
    if [ "$STARTTIME" == "0" ] && [ "$OFFSET" == "0" ]; then
        cut "$INPUT" -d, -f1-3,5 > $TMPFILE
        sed -i '1d;' $TMPFILE
    else
        # Find Start and set the output file accordingly
        INPUTTMPCPY_FILE=$(mktemp /tmp/XXXXXX)
        cp "$INPUT" "$INPUTTMPCPY_FILE"
        sed -i '1d;' "$INPUTTMPCPY_FILE"
        TOTALLINES=$(wc -l $INPUTTMPCPY_FILE | cut -d\  -f 1)
        LINEINDEXTOP=0
        OLDIFS=$IFS
        IFS=','
        while read TIME REST
        do
            compare=$(echo | awk "{ print ($TIME >= $STARTTIME) ? 1 : 0 }")
            if [ $compare -eq 1 ]; then
                break
            fi
            LINEINDEXTOP=$(expr $LINEINDEXTOP + 1)
        done < $INPUTTMPCPY_FILE
        IFS=$OLDIFS
        REMAININGLINES=$(expr $TOTALLINES - $LINEINDEXTOP)
        INPUTTMPCPY2_FILE=$(mktemp /tmp/XXXXXX)
        tail -n $REMAININGLINES $INPUTTMPCPY_FILE > $INPUTTMPCPY2_FILE

        # Now search for the stop index
        INPUTTMPCPY3_FILE=$(mktemp /tmp/XXXXXX)
        if [ $OFFSET_SEC -eq 0 ]; then
            cp $INPUTTMPCPY2_FILE $INPUTTMPCPY3_FILE
        else
            STOPTIME=$(echo | awk "{ print ($STARTTIME + $OFFSET_SEC)}")
            LINEINDEXBOTTOM=0
            OLDIFS=$IFS
            IFS=','
            while read TIME REST
            do
                compare=$(echo | awk "{ print ($TIME > $STOPTIME) ? 1 : 0 }")
                if [ $compare -eq 1 ]; then
                    break
                fi
                LINEINDEXBOTTOM=$(expr $LINEINDEXBOTTOM + 1)
            done < $INPUTTMPCPY2_FILE
            IFS=$OLDIFS
            head -n $LINEINDEXBOTTOM $INPUTTMPCPY2_FILE > $INPUTTMPCPY3_FILE
        fi

        cut $INPUTTMPCPY3_FILE -d, -f1-3,5 > $TMPFILE
        rm $INPUTTMPCPY_FILE
        rm $INPUTTMPCPY2_FILE
        rm $INPUTTMPCPY3_FILE

        if [ $OFFSET_SEC -ne 0 ] && ([ $LINEINDEXTOP -ge $TOTALLINES ] || [ $LINEINDEXBOTTOM -eq 0 ]); then
            die "Too less data points available. Choose another start time or offset!"
        fi
    fi
    echo "$TMPFILE"
}

generate_resampled_coords_file(){
    TMPFILE=$(mktemp /tmp/XXXXXX)
    if [ "$GMTVERSION" -eq 4 ]; then
        set +e
        GMT sample1d $1 -N$2 -V > $TMPFILE
        retval=$?
        set -e
    elif [ "$GMTVERSION" -eq 5 ]; then
        set +e
        gmt sample1d $1 -N$2 -sa -V > $TMPFILE
        retval=$?
        set -e
    else
        set +e
        gmt sample1d $1 -T$2 -sa -V > $TMPFILE
        retval=$?
        set -e
    fi
    if [ $retval -ne 0 ]; then
        msg "${FUNCNAME[0]}: ${YELLOW}sample1d returned an error - did you specify correct input file format? (see help on --format)${NOFORMAT}"
    fi
    echo "$TMPFILE"
}

merge_coords_and_zacc_file()
{
    # Convert tabs to comma in coordination file
    sed -i 's/\t/,/g;' $1
    sed -i 's/\t/,/g;' $2
    # We don't need time information in column 1 in the second file
    sed -i 's/^[^,]*,//g' $2

    TMPFILE=$(mktemp /tmp/XXXXXX)
    paste -d, $1 $2 > $TMPFILE
    echo "$TMPFILE"
}

create_gpx_with_track_file()
{
    # Create the gpx file with acceleration data
    TMPFILE=$(mktemp /tmp/XXXXXX)
    gpsbabel -t -i unicsv -f $1 -o gpx -F $TMPFILE
    echo "$TMPFILE"
}

create_gpx_without_track_file()
{
    # Create the gpx file with acceleration data
    TMPFILE=$(mktemp /tmp/XXXXXX)
    gpsbabel -i unicsv -f $1 -o gpx -F $TMPFILE
    echo "$TMPFILE"
}

#This function will create a gpx file with only coordinate files
#For later use the coordinates need to be in float format.
create_coords_only_gpx_file()
{
    COORDS_TMP_FILE=$(mktemp /tmp/XXXXXX)
    cut -d, -f2,3 $1 > $COORDS_TMP_FILE
    COORDSCONVERTEDTMP_FILE=$(mktemp /tmp/XXXXXX)
    OLDIFS=$IFS
    IFS=','
    # We need to convert scientific notation into float numbers
    while read LAT LON
    do
        LAT_CONV=$(echo $LAT | awk '{printf("%3.9f",$0);}')
        LON_CONV=$(echo $LON | awk '{printf("%3.9f",$0);}')
        echo "$LAT_CONV, $LON_CONV" >> $COORDSCONVERTEDTMP_FILE
    done < $COORDS_TMP_FILE
    IFS=$OLDIFS

    sed -i '1i lat, long' $COORDSCONVERTEDTMP_FILE # Include header
    RETURNFILE=$(create_gpx_with_track_file $COORDSCONVERTEDTMP_FILE)
    rm $COORDS_TMP_FILE
    rm $COORDSCONVERTEDTMP_FILE
    echo "$RETURNFILE"
}

# We expect the outcome of the analysing script to be a table with five columns
# of time, y, x, speed, and z-acceleration like this: (the table header is important!)
#time,y,x,speed,z
#5.0,49.0,8.6,6.9,58.7
#...
analyze_data_via_script()
{
    # Find the gps coordinates where the highest z acceleration values happened
    python3 "$SCRIPTPATH"/acceleration_selection.py -i $1 -b $2 -t $3 -o $4
    msg "Analysis done"
}

sort_for_and_remove_time_column()
{
    # Sort for the time and remove this column also.
    # Whith this we can create a gpx file where the positions with
    # high-z values come first where they occured first on the street.
    TMPFILE=$(mktemp /tmp/XXXXXX)
    cat $1 | (read -r; printf "%s\n" "$REPLY"; sort -g) | cut -d, -f2,3,4,5 > $TMPFILE
    echo $TMPFILE
}

correct_zaccs_for_gvalue()
{
    CORRECTION="$1"
    INPUTFILE="$2"
    OUTFILE=$(mktemp /tmp/XXXXXX)

    # $1=TIME, $2=ACC_Z
    awk -v s=${CORRECTION} '{printf("%3.9f\t%3.9f\n",$1,$2-s);}' ${INPUTFILE} >> $OUTFILE

    echo $OUTFILE
}

detect_format_comma_sep_decimal_point()
{
    FOUNDFORMAT=-1
    set +e
    COMMAFOUND=$(grep -c "\"Time (s)\"," "$GIVENFILE")
    set -e
    if [ $COMMAFOUND -gt 0 ]; then
        # Find the number of dots in the second line; it should be 5 for the Acceleration file from phyphox
        NUMBEROFDOTS=$(head -n 2 "$GIVENFILE" | tail -n 1 | tr -d -c '.' | wc -m)
        if [ $NUMBEROFDOTS -eq 4 ]; then
            FOUNDFORMAT=0
        fi
    fi
    echo $FOUNDFORMAT
}

detect_format_tabulator_sep_decimal_point()
{
    FOUNDFORMAT=-1
    set +e
    TABFOUND=$(grep -cP '\t' "$GIVENFILE")
    set -e
    if [ $TABFOUND -gt 0 ]; then
        # Find the number of dots in the second line; it should be 5 for the Acceleration file from phyphox
        NUMBEROFDOTS=$(head -n 2 "$GIVENFILE" | tail -n 1 | tr -d -c '.' | wc -m)
        if [ $NUMBEROFDOTS -eq 4 ]; then
            FOUNDFORMAT=1
        fi
    fi
    echo $FOUNDFORMAT
}

detect_format_semicolon_sep_decimal_point()
{
    FOUNDFORMAT=-1
    set +e
    SIMECOLONFOUND=$(grep -c "\"Time (s)\";" "$GIVENFILE")
    set -e
    if [ $SIMECOLONFOUND -gt 0 ]; then
        # Find the number of dots in the second line; it should be 5 for the Acceleration file from phyphox
        NUMBEROFDOTS=$(head -n 2 "$GIVENFILE" | tail -n 1 | tr -d -c '.' | wc -m)
        if [ $NUMBEROFDOTS -eq 4 ]; then
            FOUNDFORMAT=2
        fi
    fi
    echo $FOUNDFORMAT
}

detect_format_tabulator_sep_decimal_comma()
{
    FOUNDFORMAT=-1
    set +e
    TABFOUND=$(grep -cP '\t' "$GIVENFILE")
    set -e
    if [ $TABFOUND -gt 0 ]; then
        # Find the number of dots in the second line; it should be 5 for the Acceleration file from phyphox
        NUMBEROFCOMMAS=$(head -n 2 "$GIVENFILE" | tail -n 1 | tr -d -c ',' | wc -m)
        if [ $NUMBEROFCOMMAS -eq 4 ]; then
            FOUNDFORMAT=3
        fi
    fi
    echo $FOUNDFORMAT
}

detect_format_semicolon_sep_decimal_comma()
{
    FOUNDFORMAT=-1
    set +e
    SEMICOLONFOUND=$(grep -c "\"Time (s)\";" "$GIVENFILE")
    set -e
    if [ $SEMICOLONFOUND -gt 0 ]; then
        # Find the number of dots in the second line; it should be 5 for the Acceleration file from phyphox
        NUMBEROFCOMMAS=$(head -n 2 "$GIVENFILE" | tail -n 1 | tr -d -c ',' | wc -m)
        if [ $NUMBEROFCOMMAS -eq 4 ]; then
            FOUNDFORMAT=4
        fi
    fi
    echo $FOUNDFORMAT
}

detect_format()
{
#   Return values are the following, depending on the input format of the csv data files
#    0: Comma, decimal point
#    1: Tabulator, decimal point
#    2: Semicolon, decimal point
#    3: Tabulator, decimal comma
#    4: Semicolon, decimal comma
    GIVENFILE="$1"
    #0
    FOUNDFORMAT=$(detect_format_comma_sep_decimal_point "$GIVENFILE")
    #1
    if [ $FOUNDFORMAT -eq -1 ]; then
        FOUNDFORMAT=$(detect_format_tabulator_sep_decimal_point "$GIVENFILE")
    fi
    #2
    if [ $FOUNDFORMAT -eq -1 ]; then
        FOUNDFORMAT=$(detect_format_semicolon_sep_decimal_point "$GIVENFILE")
    fi
    #3
    if [ $FOUNDFORMAT -eq -1 ]; then
        FOUNDFORMAT=$(detect_format_tabulator_sep_decimal_comma "$GIVENFILE")
    fi
    #4
    if [ $FOUNDFORMAT -eq -1 ]; then
        FOUNDFORMAT=$(detect_format_semicolon_sep_decimal_comma "$GIVENFILE")
    fi
    echo $FOUNDFORMAT
}


execute()
{
    msg "Remove duplicate a_z's"
    NODOUBLELINESACCELEROMETERFILE=$(remove_duplicates "$ACCELEROMETERFILE")
    msg "Remove duplicate coords"
    NODOUBLELINESLOCATIONFILE=$(remove_duplicates "$LOCATIONFILE")
    msg "Detect format"
    CSVFORMAT=$(detect_format "$ACCELEROMETERFILE")
    if [ $CSVFORMAT -lt 0 ]; then
        msg "${FUNCNAME[0]}: ${RED}Error${NOFORMAT} - Format of input file could not be detected!"
        msg "Valid CSV file formats (export formats in the phyphox app) are:"
        msg "- Comma, decimal point"
        msg "- Tabulator, decimal point"
        msg "- Semicolon, decimal point"
        msg "- Tabulator, decimal comma"
        msg "- Semicolon, decimal comma"
        msg "... stoping here."
        rm "$NODOUBLELINESACCELEROMETERFILE"
        rm "$NODOUBLELINESLOCATIONFILE"
        die
    fi
    case "$CSVFORMAT" in
        #Comma, decimal point, nothing to reformat
        0) echo "Comma separator, decimal point found" ;;
        #Tabulator, decimal point
        1) echo "Tabulator separator, decimal point found" ;;
        #Semicolon, decimal point
        2) echo "Semicolon separator, decimal point found" ;;
        #Tabulator, decimal comma
        3) echo "Tabulator separator, decimal comma found" ;;
        #Semicolon, decimal comma
        4) echo "Semicolon separator, decimal comma found" ;;
    esac
    msg "Format a_z's"
    FORMATEDACCELEROMETERFILE=$(convert_data "$CSVFORMAT" "$NODOUBLELINESACCELEROMETERFILE")
    msg "Format coords"
    FORMATEDLOCATIONFILE=$(convert_data "$CSVFORMAT" "$NODOUBLELINESLOCATIONFILE")
    msg "Extract a_z's"
    ZACCLSFILE=$(export_times_and_zaccs_in_file "$FORMATEDACCELEROMETERFILE")
    msg "Extract coords"
    COORDSFILE=$(export_time_lat_long_speed $START $OFFSET "$FORMATEDLOCATIONFILE")

    msg "Resample coords"
    COORDS_RESAMPLED_FILE=$(generate_resampled_coords_file $COORDSFILE $ZACCLSFILE)
    if [ $(wc -l "$COORDS_RESAMPLED_FILE" | cut -d ' ' -f 1) -lt 2 ]; then
        msg "${RED}Error${NOFORMAT}: Not enough coordinates found for the given time frame. Stopping here."
        rm "$COORDSFILE"
        rm "$NODOUBLELINESACCELEROMETERFILE"
        rm "$NODOUBLELINESLOCATIONFILE"
        rm "$FORMATEDACCELEROMETERFILE"
        rm "$FORMATEDLOCATIONFILE"
        rm "$ZACCLSFILE"
        rm "$COORDS_RESAMPLED_FILE"
        die;
    fi

    msg "Resample a_z's"
    ZACCLS_RESAMPLED_FILE=$(generate_resampled_coords_file $ZACCLSFILE $COORDS_RESAMPLED_FILE)
    if [ $(wc -l "$ZACCLS_RESAMPLED_FILE" | cut -d ' ' -f 1) -lt 2 ]; then
        msg "${RED}Error${NOFORMAT}: Not enough acceleration values found for the given time frame. Stopping here."
        rm "$COORDSFILE"
        rm "$NODOUBLELINESACCELEROMETERFILE"
        rm "$NODOUBLELINESLOCATIONFILE"
        rm "$FORMATEDACCELEROMETERFILE"
        rm "$FORMATEDLOCATIONFILE"
        rm "$ZACCLSFILE"
        rm "$COORDS_RESAMPLED_FILE"
        rm "$ZACCLS_RESAMPLED_FILE"
        die;
    fi

    #Correct the measured acceleration values for the g-value (time consuming!)
    if [ "$GVALUE" != "0.0" ]; then
        msg "Correct for g"
        TMPFILE=$(mktemp /tmp/XXXXXX)
        mv $ZACCLS_RESAMPLED_FILE $TMPFILE
        ZACCLS_RESAMPLED_FILE=$(correct_zaccs_for_gvalue $GVALUE $TMPFILE)
        rm $TMPFILE
    fi

    msg "Merge coords and a_z's"
    MERGEDMEASUREDATAFILE=$(merge_coords_and_zacc_file $COORDS_RESAMPLED_FILE $ZACCLS_RESAMPLED_FILE)

    # Remove lines which start with a comma after merging (if there are any)
    sed -i '/^,/d' $MERGEDMEASUREDATAFILE

    COORDSANDACCSFILE=$(mktemp /tmp/XXXXXX)
    cp $MERGEDMEASUREDATAFILE $COORDSANDACCSFILE

    # We don't need time information in column 1 for generating a gpx file
    sed -i 's/^[^,]*,//g' $COORDSANDACCSFILE
    sed -i '1i y, x, speed, z' $COORDSANDACCSFILE # Include header

    msg "Create gpx output file"
    GPXPATHANDZACCFILE=$(create_gpx_with_track_file $COORDSANDACCSFILE)

    if [ "$ANALYSIS" = "YES" ] && [ "$ISPYTHON3HERE" = "YES" ] && [ "$MAXZCALCSCRIPTFOUND" = "YES" ]; then
        msg "Find maximum positions"
        # Include header - this file will be used below to analyze the data
        TIMECOORDSZACCSFILE=$(mktemp /tmp/XXXXXX)
        sed '1i time, y, x, speed, z' $MERGEDMEASUREDATAFILE > $TIMECOORDSZACCSFILE

        # output file of the python script
        HIGHZCOORDSTMPFILE=$(mktemp /tmp/XXXXXX)

        # Find the gps coordinates where the highest z acceleration values happened
        analyze_data_via_script $TIMECOORDSZACCSFILE $BAD_STREET_POSITIONS $TIME_WINDOW $HIGHZCOORDSTMPFILE

        TIMESORTEDZCOORDSTMPFILE=$(sort_for_and_remove_time_column $HIGHZCOORDSTMPFILE)

        ZMAXCOORDSGPXFILE=$(create_gpx_without_track_file $TIMESORTEDZCOORDSTMPFILE)

        msg "Merge findings with gpx output file"
        if [ $MAXONLY == "YES" ]; then
            GPXPATHFILE=$(create_coords_only_gpx_file $COORDSFILE)
            # Merge path coordinates and max-Z accelerations gpx file (dont export actual z acceleration data)
            gpsbabel -i gpx -f $ZMAXCOORDSGPXFILE -i gpx -f $GPXPATHFILE -o gpx -F $OUTPUTFILENAME
            rm $GPXPATHFILE
        else
            # Merge the GPX file with high Z-coords and the complete GPX path into one merged GPX output file
            gpsbabel -i gpx -f $ZMAXCOORDSGPXFILE -i gpx -f $GPXPATHANDZACCFILE -o gpx -F $OUTPUTFILENAME
        fi

        rm $TIMECOORDSZACCSFILE
        rm $HIGHZCOORDSTMPFILE
        rm $TIMESORTEDZCOORDSTMPFILE
        rm $ZMAXCOORDSGPXFILE
        rm $GPXPATHANDZACCFILE
    else
        mv $GPXPATHANDZACCFILE $OUTPUTFILENAME
    fi

    rm $COORDSFILE
    rm $COORDSANDACCSFILE
    rm $NODOUBLELINESACCELEROMETERFILE
    rm $NODOUBLELINESLOCATIONFILE
    rm $FORMATEDACCELEROMETERFILE
    rm $FORMATEDLOCATIONFILE
    rm $ZACCLSFILE
    rm $ZACCLS_RESAMPLED_FILE
    rm $COORDS_RESAMPLED_FILE
    rm $MERGEDMEASUREDATAFILE

    msg "${GREEN}Done${NOFORMAT}: $OUTPUTFILENAME"
}

main()
{
    # Some setup
    setup_colors
    check_dependencies
    set_gmt_binary
    parse_params "$@"
    validate_input
    setup_input_vars
    setup_test_vars
    check_for_python3

    # Execute tests if needed
    if [ $TEST == "YES" ]; then
        do_regression_tests
        exit 0
    fi

    # And go
    execute
}

main "$@"
