####################################################################################
# This script will return a table consisting of the highest acceleration (z) values
# by taking into account a minimal time difference between those values.
#
# Script by Maik Pertermann, 2020
####################################################################################

# usage:
# python acceleration_selection.py <input.csv> <number of rows>
# <time difference> <optional: output.csv>

# python ./acceleration_selection.py /home/maik/uwe/xyz_data.csv 5 2

# load modules; Check for pandas happens at the end
import sys, getopt

def main(argv):
    # Get full command-line arguments
    full_cmd_arguments = argv

    short_options = "hi:o:t:b:"
    long_options = ["help", "input=", "output=", "timewindow=", "numberofbumps="]

    try:
        arguments, values = getopt.getopt(full_cmd_arguments, short_options, long_options)

    except getopt.error as err:
        # Output error, and return with an error code
        print (str(err))
        print_usage()
        sys.exit(2)

    input_csv=""
    output_csv=""
    timevariation=2
    numrow=5

    # Evaluate given options
    for current_argument, current_value in arguments:
        if current_argument in ("-h", "--help"):
            print_usage()
            sys.exit(0)
        elif current_argument in ("-i", "--input"):
            input_csv = current_value
        elif current_argument in ("-o", "--output"):
            output_csv = current_value
        elif current_argument in ("-t", "--timewindow"):
            timevariation = int(current_value)
        elif current_argument in ("-b", "--numberofbumps"):
            numrow = int(current_value)

    df_selected = fkt_select(input_csv, numrow, timevariation)

    # output
    if output_csv != "":
        df_selected.to_csv(output_csv, sep=',', index=False)
    else:
        print(df_selected.to_string(index=False))

def print_usage():
    print('usage:')
    print()
    print('python acceleration_selection.py -i <input.csv> -b <number of rows>\n'\
          '-t <time difference> -o <output.csv>')
    print()
    print('-t, -o and -g are optional values')


def fkt_select(input_csv, numrow, timevariation):
    # read csv
    df=pd.read_csv(input_csv, sep=',')
    # replace space in column names
    df.columns = df.columns.str.replace(' ', '')
    # adjust acceleration z
    df['z'] = abs(df['z'])
    # sort by z
    df_sorted = df.sort_values('z', ascending=False)
    df_sorted = df_sorted.reset_index()
    # select
    df_selected = df_sorted[0:1]
    i = 1
    ii = 1
    while (i <= numrow - 1) & (ii <= df_sorted.shape[0] - 1):
        #print(i, ii, round(df_sorted['time'][ii],2), round(df_sorted['time'][ii-1],2), round(df_sorted['time'][ii+1],2))
        if abs(df_sorted['time'][ii] - df_sorted['time'][ii-1]) >= timevariation:
            writerow = True
            for itime in df_selected['time']:
                #print('itime', round(itime,2))
                if (abs(df_sorted['time'][ii] - itime) < timevariation):
                    writerow = False
                    break
            if writerow == True:
                df_selected = pd.concat([df_selected, df_sorted.take([ii])], axis=0, ignore_index=True)
                i += 1
        ii += 1
    df_selected = df_selected[['time', 'y', 'x', 'speed', 'z']]
    return(df_selected)

if __name__ == "__main__":
    try:
        import pandas as pd
    except ModuleNotFoundError as error:
        print("You dont have module pandas installed. In Ubuntu, install with pip via \"sudo pip install pandas\".")
        exit()
    main(sys.argv[1:])


