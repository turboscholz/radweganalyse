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

# load modules
import pandas as pd
import sys, getopt

def main(argv):
    try:
        input_csv = argv[0]
        numrow = int(argv[1])
        timevariation = int(argv[2])
        #print(len(argv))
        #print(input_csv, numrow, timevariation)
        # compute
        df_selected = fkt_select(input_csv, numrow, timevariation)
        #print(df_selected.shape)
        # output
        if len(argv) == 4:
            output_csv = argv[3]
            df_selected.to_csv(output_csv, sep=',', index=False)
        else:
            print(df_selected.to_string(index=False))
    except:
        print('usage:')
        print('# python acceleration_selection.py <input.csv> <number of rows>\n'\
              '# <time difference> <optional: output.csv>')

def fkt_select(input_csv, numrow, timevariation):
    # read csv
    df=pd.read_csv(input_csv, sep=',')
    # replace space in column names
    df.columns = df.columns.str.replace(' ', '')
    # adjust acceleration z
    df['z'] = abs(df['z'] - 9.81)
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
                df_selected = df_selected.append(df_sorted.iloc[ii], ignore_index=True)
                #print(df_selected)
                i += 1
        ii += 1
    df_selected = df_selected[['time', 'y', 'x', 'speed', 'z']]
    return(df_selected)

if __name__ == "__main__":
   main(sys.argv[1:])


