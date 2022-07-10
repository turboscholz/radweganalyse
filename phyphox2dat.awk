#Converts phyphox-Data (Location+Acceleration), combines them and interpolate location
#
#Count Levels from phyphox-Accelartion-files, column 4 (a_z) and count the max between two 0-crossings
#only for peaks which exceed a certan deadbandwidth (-v deadb)
#
#GPX: https://de.wikipedia.org/wiki/GPS_Exchange_Format
#
#usage:
#gawk -f ../../bin/interpol_gpx_v02.awk
#
#Known Bugs/Limitations:
#-Do not know, how it behaves if experiment is set without "g"
#-Didn't tested on systems with , as decimal separator (unix drives here with . ;-)
#
#Solved Bugs:
#
BEGIN{
if (inf1=="") {inf1="Location.csv"}		#default by current phyphox
if (inf2=="") {inf2="Accelerometer.csv"}	#default by current phyphox
if (inf3=="") {inf3="meta/time.csv"}		#default by current phyphox
if (out1=="") {out1="Interpol.dat"}		#adjuste by demand
if (out2=="") {out2="Interpol.gpx"}		#adjuste by demand
if (out3=="") {out3="LevelCrossing.dat"}	#adjuste by demand
if (nle=="") {nle=60}				#Levels between max and min for out3
if (deadb=="") {deadb=0.3}			#|deadbandwidth|, below this no max/min counted for out3
#
#normally no adaption below this
max=-99999;min=99999		#preset
#
print " Reading -v inf3= "inf3" ..."
while (getline zeile<inf3 >0)
 {n=split(zeile,a,";")			#;-separator
  if (n==1) {n=split(zeile,a,"\t")}	#tab-separator
  if (n==4 && a[1]=="\042START\042")
   {split(a[4],b," ");date=substr(b[1],2);time=b[2]}
 }
print "  measurement started on "date" at "time" ."
# Header for out1
print "#generated with gawk -f interpol_gpx_v02.awk -v inf1= " inf1" -v inf2= "inf2 " -v out1= "out1 >out1
print "#time            lat      long     v         a_z">>out1
print "#[s]          [Grad]    [Grad] [km/h]        [g]">>out1
print "#1                 2         3      4          5">>out1
# Header for out2
print "<?xml version=\0421.0\042 encoding=\042UTF-8\042?>">out2
print "<gpx version=\0421.0\042 creator=\042interpol_gpx.awk\042>">>out2
print " <time>"date"T"time"Z</time>" >>out2
#
print " Testing -v inf2= "inf2" for type of delimiter and decimal separator..."
for (i=1;i<=2;i++)
 {getline zeile<inf2>0}
n1=split(zeile,a,";")
n2=split(zeile,a,",")
n3=split(zeile,a," ")
n4=split(zeile,a,".")
n5=split(zeile,a,"\t")
if (n2==4 && n4==5) {fs="," ;sd=".";fss=","}
if (n5==4 && n4==5) {fs="\t";sd=".";fss="TAB"}
if (n1==4 && n4==5) {fs=";" ;sd=".";fss=";"}
if (n5==4 && n2==5) {fs="\t";sd=",";fss="TAB"}
if (n1==4 && n2==5) {fs=";" ;sd=",";fss=";"}
if (fs=="" || sd=="") {print " Unknown Format";EXIT}
close(inf2)
print "  found "fss" as delimiter and "sd" as decimal separator."
if (sd==",") {print " Converting to decimal separator \042.\042 !"}
#
maxlat=-90;minlat=90;maxlon=-180;minlon=180
print " Reading -v inf1= "inf1" .."
while (getline zeile<inf1 >0)
 {if (sd==",") {gsub(",",".",zeile)}
  n=split(zeile,a,fs)
  if (n==8 && a[1]+0>0)
   {t=a[1]+0;lat=a[2]+0;lon=a[3]+0;hei=a[4]+0;vel=a[5]+0;dir=a[6]+0;hoa=a[7]+0;vea=a[8]+0
    il++;tff[il]=t
    tf[il,1]=t;tf[il,2]=lat;tf[il,3]=lon;tf[il,4]=hei;tf[il,5]=vel;tf[il,6]=dir;tf[il,7]=hoa;tf[il,8]=vea
    if (wptlat=="") {wptlat=lat;wptlon=lon}	#Startvalues
    if (minlat>lat) {minlat=lat}
    if (maxlat<lat) {maxlat=lat}
    if (minlon>lon) {minlon=lon}
    if (maxlon<lon) {maxlon=lon}
   }
 }
print "  found "il" values for location"
#
printf(" <bounds minlat=\042%.5f\042 minlon=\042%.5f\042 maxlat=\042%.5f\042 maxlon=\042%.5f\042/>\n",minlat,minlon,maxlat,maxlon)>>out2
printf(" <wpt lat=\042%.5f\042 lon=\042%.5f\042>\n",wptlat,wptlon)>>out2
print  "  <name>WPT001</name>"		>>out2
print  "  <cmt>WPT001</cmt>"		>>out2
print  "  <desc>WPT001</desc>"		>>out2
print  " </wpt>"			>>out2
#print  " <metadata> <!-- Metadaten --> </metadata>" >>out2
print  " <trk>"				>>out2
print  "  <trkseg>"			>>out2
#
print " Reading -v inf2= "inf2" .."
while (getline zeile<inf2 >0)
 {if (sd==",") {gsub(",",".",zeile)}
  n=split(zeile,a,fs)
  if (n==4)
   {t=a[1]+0;ax=a[2]+0;ay=a[3]+0;az=a[4]+0
    gz=(a[4]/9.81)-1
    if (gz*gzv<0 && gzv!="") #sign-change=0-Crossing
     {if (gz<0)
      {if (gmax>deadb) {f[gmax]++}	#previous maxi
       gmin=0;gmax=0}
      else
      {if (gmin<-deadb) {f[gmin]++}	#previous mini
       gmax=0;gmin=0}
     }
    if (gz<gmin) {gmin=gz}
    if (gz>gmax) {gmax=gz}
    if (gz<min)  {min=gz}		#overall min
    if (gz>max)  {max=gz}		#overall max
    ifo++
    gzv=gz
    ia++;taf[ia]=t
    ta[ia,1]=t;ta[ia,2]=ax;ta[ia,3]=ay;ta[ia,4]=az}
 }
print "  found "ia" values for acceleration"
#
print " Generating for acceleration the locations by interpolation..."
j=1
for (i=1;i<=ia;i++)
 {t=taf[i]
  if (t>tl)
   {for (j=j;j<=il;j++)
    {tl=tff[j];if (tl>t) {break}
     tlv=tl
    }
   }
  p1=j-1;p2=j		#Locations pre/post current acceleration
  t1=tf[p1,1];lat1=tf[p1,2];lon1=tf[p1,3];vel1=tf[p1,5]
  t2=tf[p2,1];lat2=tf[p2,2];lon2=tf[p2,3];vel2=tf[p2,5]
#  print t" "t1" "t2" "p1" "p2
  if (t1<t && t1!=0 && t2>t)
    {lati=lat1+(t-t1)*(lat2-lat1)/(t2-t1)
     loni=lon1+(t-t1)*(lon2-lon1)/(t2-t1)
     veli=vel1+(t-t1)*(vel2-vel1)/(t2-t1)
     printf("%-10.2f %-10.6f %-10.6f %-8.2f %6.2f\n",t,lati,loni,veli*3.6,ta[i,4]/9.81-1)>>out1
     printf("   <trkpt lat=\042%.6f\042 lon=\042%.6f\042>\n",lati,loni)>>out2
     printf("    <ele>%.2f</ele>\n",ta[i,4]/9.81-1)>>out2
     printf("    <speed>%.2f</speed>\n",veli)>>out2
     printf("   </trkpt>\n")>>out2
    }
   else {}
 }
print "  -v out1= "out1 " written"
#
print "  </trkseg>">>out2
print " </trk>">>out2
print "</gpx>">>out2
print "  -v out2= "out2 " written"
#
#now the level-crossing-statistic-output
print " Found "ifo" values between "min" and "max" g."
k=0;l=0;for (j in f) {k++;l+=f[j]}
print "  to be separated in "k" discrete peak-Values and "l" peaks above | -v deadb= "deadb "| [g] ."
print " Writing now -f out3= "out3" ..."
delta=(max-min)/nle
print "  with -v nle= "nle" steps (Delta= "delta" )."
print "#generated with gawk -v interpol_gpx_v02.awk -v deadb= "deadb" -v nle= "nle "" >out3
print "#level		n  n/n_max\n#1		2	 3">>out3
nsmax=0
for (x=min;x<=max;x+=delta)			#1st loop to catch nsmax!
 {ns=0
  for (j in f) {if (j+0>=x && j+0<x+delta) {ns+=f[j]}}
  if (ns>0) {fx[x]=ns;if (ns>nsmax) {nsmax=ns}}
 }
for (x=min;x<=max;x+=delta)			#2nd loop for writing
 {if (fx[x]>0) {printf("%-8.3f %8d %8.5f\n",x,fx[x],fx[x]/nsmax)>>out3}}
#
print " Finished"
}
