# 🚲📱📈 - Bicycle path surface quality measured with the smartphone

This repository contains the shell script `radweganalyse.sh` which converts exported
GPS data and acceleration data measured with the app [phyphox](https://phyphox.org/)
into a GPX file for graphical analysis with common graphical GPS programs.

Furthermore, you will find the experiment description file `radweganalyse.phyphox` which
can be imported into the phyphox app. It will create a new experiment entry for the parallel
read-out of the GPS sensor and the acceleration sensor of your mobile phone.

After exporting the measured data as comma-separated CSV files, these files are located on the
smartphone as a zip archive. This zip needs to be copied over to your PC. Unzip it into
a new folder. Then, execute the script `radweganalyse.sh` in the same directory where you
have placed the CSV files.

Without adding any arguments, the script will create the output file `xyz_data.gpx` for
the complete data set. It will also check if the required dependencies are available
on your system and show an error if this is not the case.

Executing `radweganalyse.py --help` will show you a number of possible program options.

The script also contains unit tests which can be executed by `radweganalyse.sh --test`. If all
tests pass you can be sure that the script is doing what it should be doing.

The python script `acceleration_selection.py` is used to find the maximum z-acceleration
in the measured data.
