#!/bin/bash

# Script to complete the json files after conversion into BIDS format
#
#   1) Add the number of repetitions to the functional runs jsons.
#   2) Populate the 'Intendedfor' field in the json files for the field maps.
#   3) Fix the "CogAtlasID" field for all the task json files.
#
#   It is supposed to run on Linux and Mac OSX, and needs either FSL, FreeSurfer or AFNI.
#
#   Note: the logic behind the way we decide how to populate the "IntendedFor" is:
#     We want all images in the session (except for the fmap images themselves) to
#     have AT MOST one fmap.  (That is, a pair of SE EPI with reversed polarities, or
#     a magnitude a phase field map).
#     If there are more than one fmap (more than a fmap pair) with the same acquisition
#     parameters as, say, a functional run, we will just assign that run to the FIRST
#     pair, while leaving the other fmap pairs without any assigned images.  If the
#     user's intentions were different, he will have to manually edit the fmap json files.
#

show_usage() {
cat <<EOF
completeJSONs.sh: Script to complete the json files after conversion into BIDS format

Usage: completeJSONs.sh <BIDS-session>
    <BIDS-session>: path to the session to process.
          If the subject's data doesn't include sessions, use the path
          to the subject's folder
EOF
}


# Check number of parameters:
if [ "$#" = "0" ]; then
    echo "Illegal number of parameters"
    show_usage
    exit 1
fi

verbose=       # non-verbose by default
if [[ $# -eq 2 ]] && [[ $2 == true ]]; then
    verbose=true        # verbose output
fi

if [ -f /CBI/CBI.sh ]; then
    source /CBI/CBI.sh
fi

# Check what tool we have installed in the system to get info from NIfTI files:
if [ ! -z "${FSLDIR+x}" ]; then
    NIFTI_TOOL=FSL
    # check if FSL has been configured:
    if [ -z "$FSLOUTPUTTYPE" ]; then
   .    ${FSLDIR}/etc/fslconf/fsl.sh
    fi
elif [ ! -z "${FREESURFER_HOME+x}" ]; then
    NIFTI_TOOL=FREESURFER
elif [ command -v afni &> /dev/null ]; then
    NIFTI_TOOL=AFNI
else
    echo "We didn't find a tool to get info from NIfTI files."
    echo "You need to have FSL, FreeSurfer or AFNI installed, "
    echo "and the variables FSLDIR or FREESURFER_HOME set."
    exit 1
fi
echo "NIFTI_TOOL: $NIFTI_TOOL"


#     #     #     #     #     #     #     #     #     #     #     #     #     #     #     
#
# get_numberofvolumes()
#
# Description:
# 
#   Gets the number of volumes from a NIfTI file
#
#   We can either use FSL or FreeSurfer, whichever is found in the system
#
# Input:
# 
#   The NIfTI file
#
get_numberofvolumes() {
    f="$1"

    case $NIFTI_TOOL in

	FSL)
	    nvols=$( ${FSLDIR}/bin/fslnvols "$f" )    # <-- This is the output of the function
	    ;;

	FREESURFER)
	    nvols=$( ${FREESURFER_HOME}/bin/mri_info "$f" --nframes )
	    ;;

	AFNI)
	    nvols=$( 3dinfo -nv "$f" )
	    ;;

	*)
	    echo "NIFTI_TOOL is incorrect. We can't proceed."
	    exit 1
    esac
    echo $nvols        # <-- This is the output of the function
    return
}


#     #     #     #     #     #     #     #     #     #     #     #     #     #     #     
#
# add_numberofvols()
#
# Description:
# 
#   Adds a 'NumberOfVolumes' field to a .json file.
#
# Input:
# 
#   The json file to be edited.
#
add_numberofvols() {
    jFile="$1"
    # corresponding NIfTI file:
    niiFile=( $(ls ${jFile%.json}.nii*) )

    # get number of volumes
    nVols=( $(get_numberofvolumes ${niiFile}) )

    #
    # Let's figure out if we need to create a brand new field or just add entries to an existing one
    test $(grep -c "\"NumberOfVolumes\":" $jFile) -gt 0
    let insertIt=$?
    [ $verbose ] && echo "Insert? $insertIt"

    #
    # If field already present, just overwrite it. If not, figure out where to place it:
    if [ $insertIt -eq 0 ]
    then
	# Already there: just overwrite it with the correct value:
	sed -i -e "s/\([ ]*\)\"NumberOfVolumes\": \([0-9]*\),/\1\"NumberOfVolumes\": ${nVols},/" $jFile

    else
	# Add the "NumberOfVolumes" field at the end of the file:

	# Find the last line that starts with a "}".
	# (We don't assume that it is the very last line in the file)
	((preLen=( $(grep "^}" -n $jFile | cut -d : -f 1) - 1 )))

	# Then, copy those lines to the temporary json file and
	#   add a comma at the end:
	tmpFile=$(mktemp "${TMPDIR:-/tmp}/foo.XXXXXXXX.json")
	foo=$(head -n $preLen $jFile)
        echo "${foo}," > $tmpFile

	# Add the new field we want to include (without a comma at the end,
	#   since this is the last field):
	echo "  \"NumberOfVolumes\": ${nVols}" >> $tmpFile
	
	# And copy the rest of the file right afterwards:
	((postLen=( $(cat $jFile | wc -l) - $preLen + 1)))
	tail -n $postLen $jFile >> $tmpFile

	# Finally, replace the original json file with the temporal one:
	mv $tmpFile $jFile
    fi
}


#     #     #     #     #     #     #     #     #     #     #     #     #     #     #     
#
# read_header_param()
#
# Description:
# 
#   Reads a multi-line parameter from a given .json file (e.g., "ImageType")
#
# Input:
# 
#   The first argument is the parameter name (exactly as it appears in the file,
#      without quotes; if it has scaped quotes, it will not work)
#   The second argument is the json file with the header parameters
#
read_header_param() {
    paramName="$1"
    jsonFile="$2"

    # If line ends in '[' multiple values, otherwise just one
    if [ $(egrep -c "$paramName\":.*\[" $jsonFile) -eq 1 ]
    then
	# grab whatever is between the square brackets following '"$paramName":'
	myTmp=$(egrep -o "$paramName\": \[([^]]+)\]" $jsonFile)
	myTmp=${myTmp#*[}
	echo ${myTmp%]}
    else
	myTmp=$(egrep "$paramName\":.*," $jsonFile)
	myTmp=${myTmp#*: }
	echo ${myTmp%,}
    fi
    return
}


#     #     #     #     #     #     #     #     #     #     #     #     #     #     #     
#
# get_json_dims_etc()
#
# Description:
# 
#   Get the dimensions and other relevant params from a .json file
#
#   I'm going to use 'fslinfo' or 'mri_info' because the only way to get the dimensions
#     slices from the json field is by reading the SliceTiming, which seems
#     very convoluted to me.  Also, you can get the image dimensions and 
#     resolution all in one line.
#
# Input:
# 
#   The json file to be read.
#
# Output:
# 
#   An array with the relevant parameters.
#
get_json_dims_etc() {
    jsonFile="$1"
    f=$(ls ${jsonFile%.json}.nii*)

    case $NIFTI_TOOL in

	FSL)
	    # run 'fslinfo', get only the lines dim1-3 or pixdim1-3, consolidate
	    #   multiple spaces, and get the second field (the values themselves):
	    foo=($(fslinfo "$f" | grep dim[1-3] | tr -s [:blank:] | cut -d$' ' -f 2))
	    ;;

	FREESURFER)
            foo=$( (${FREESURFER_HOME}/bin/mri_info "$f" --dim \
	               && ${FREESURFER_HOME}/bin/mri_info "$f" --res) \
		       | cut -d$' ' -f1-3 )
	    ;;

	AFNI)
	    # get the four dimensions, plus the voxel size, remove blank space
	    foo=$( 3dinfo -n4 -ad3 "$f" | tr "[:blank:]" " " | cut -d$' ' -f1-3,5-7 )
	    ;;

	*)
	    echo "NIFTI_TOOL is incorrect. We can't proceed."
	    exit 1
    esac

    # keep only 3 significant digits:
    dimsEtc=$(for d in ${foo[@]}; do echo "scale=3; ${d}/1" | bc; done)

    echo ${dimsEtc[@]}    # <-- This is the output of the function
    return
}


#     #     #     #     #     #     #     #     #     #     #     #     #     #     #     
#
# get_acq_and_run()
#
# Description:
# 
#   Get the acquisition type and run number for a .json file
#
#   We just parse the json file name.
#   If the acquisition type is not specified, return "NONE".
#   If the run number       is not specified, return "00".
#
# Input:
# 
#   The json file to be read.
#
# Output:
# 
#   Two strings with the acquisition type and run number.
#
get_acq_and_run() {
    jsonFile="$1"

    # get the acquisition for this json file:
    foo=${jsonFile##*_acq-}
    if [ "$foo" == "$jsonFile" ]
    then
	# there was no "_acq-" in $jsonFile:
	myAcq="NONE"
    else
	myAcq=${foo%%_*}
    fi

    # get the run number:
    boo=${jsonFile##*_run-}
    if [ "$boo" == "$jsonFile" ]
    then
	# there was no "_run-" in $jsonFile:
	myRun=00
    else
	myRun=${boo%%_*}
    fi

    echo "$myAcq $myRun"    # <-- This is the output of the function
    return
}


#     #     #     #     #     #     #     #     #     #     #     #     #     #     #     
#
# add_intendedfor()
#
# Description:
# 
#   Adds an 'IntendedFor' field to a .json file for a field map.
#   It is the responsibility of the calling function to make sure that the files to
#     be included in the 'IntendedFor' have the same 'ShimSetting' as the json file.
#
# Input:
# 
#   The first argument is the json file to be edited.
#   The rest of the arguments are the files that will be added to the 'IntendedFor' field.
#
add_intendedfor() {
    jFile="$1"
    fileList=("${@:2}")

    myString="IntendedFor"     # variable to be use throughout this function

    #
    # Work on a temp file:
    tmpFile=$(mktemp "${TMPDIR:-/tmp}/foo.XXXXXXXX.json")

    #
    # Let's figure out if we need to create a brand new field or just entries to an existing one
    test $(grep -c "\"${myString}\":" $jFile) -gt 0
    let insertIt=$?
    [ $verbose ] && echo "Insert? $insertIt"

    #
    # Figure out how many lines to copy from original. If field not already present, figure out where to place it
    if [ $insertIt -eq 0 ]
    then
	# Already there
	((preLen=( $(grep "\"${myString}\":" -n $jFile | cut -d : -f 1) + $(read_header_param ${myString} $jFile | wc -w) )))
	echo -n "$(head -n $preLen $jFile)" > $tmpFile
	echo "," >> $tmpFile
	# since "IntendedFor" was already there, there is a "]," at the end of it.
	#  So set preLen to one more so we don't copy it again:
	((preLen=$(( $preLen + 1 ))))
	# Get a list of the "IntendedFor" files originally in the json file:
	originalFiles=$(read_header_param ${myString} ${jFile})
    else
	# Add the "IntendedFor" field at the end of the file:

	# Find the last line that starts with a "}".
	# (We don't assume that it is the very last line in the file)
	((preLen=( $(grep "^}" -n $jFile | cut -d : -f 1) - 1 )))
    
	# Then, copy those lines to the temporary json file and
	#   add a comma at the end:
	foo=$(head -n $preLen $jFile)
        echo "${foo}," > $tmpFile

	# write "IntendedFor": [ to the $tmpFile
	echo "  \"${myString}\": [" >> $tmpFile
	
	# Also, set the list of original files in the 'IntendedFor' field to empty:
	originalFiles=""
    fi

    # now, check how many lines are there from $preLen to the end of the file
    #  (we'll copy those lines at the end of $tmpFile later):
    ((postLen=( $(cat $jFile | wc -l) - $preLen )))
    # (If the original json file ends with "}" with no new line at the end.
    #  In that case, postLen might be 0, but we want to copy that last line):
    if [ $postLen -eq 0 ]
    then
	postLen=1
    fi

    # loop through the $fileList and add them:
    let fileIndex=0
    while [ $fileIndex -lt ${#fileList[@]} ]
    do
	File=${fileList[$fileIndex]}
	let fileIndex+=1

	# Check if it was originally in the IntendedFor field:
	if ( $(echo ${originalFiles[*]} | grep -w $File > /dev/null) )
	then
	    # skip it
	    echo "WARNING: \"${File}\" was already included."
	else
	    # Add this file to the "IntendedFor" field
	    if [ $fileIndex -lt ${#fileList[@]} ]
	    then
		echo "    \"${File}\"," >> $tmpFile
	    else
		# The last item in the list shouldn't be followed by ","
		echo "    \"${File}\"" >> $tmpFile
	    fi
	fi
    done

    # In case "IntendedFor" already existed, but we didn't add any new
    #   functional files to the list, remove the last comma in the last line:
    sed -i -e '$ s/,$//' $tmpFile
    
    # close square bracket:
    if [ $insertIt -eq 0 ]
    then
	# copy the line with the closing square bracket from the original
	#   file.  This way, if it was in the middle of the file, it will
	#   add the comma after the "]", and if it was at the end, it will
	#   only add "]".
	# The last line of the "IntendedFor" will be line $preLen
	sed "${preLen}q;d" $jFile >> $tmpFile
    else
	# if we added it, since we added it at the end of the file, it
	#   will be the last field, and doesn't have a comma after it.
	echo "  ]" >> $tmpFile
    fi

    # copy rest of file
    tail -n $postLen $jFile >> $tmpFile

    # move to the final destination:
    mv $tmpFile $jFile

}


#     #     #     #     #     #     #     #     #     #     #     #     #     #     #
#     #     #     #                    Main                 #     #     #     #     #
#     #     #     #     #     #     #     #     #     #     #     #     #     #     #


# remove the trailing slash, just in case:
session=${1%/}
# Get the full path:
session=$(
    realpath $session 2> /dev/null \
	|| python -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' $session \
)

## For all the functional runs, add the number of volumes in the image file:
echo "Adding 'NumberOfVolumes' to the functional runs in ${session}"

funcJsonList=( $(ls ${session}/func/*_bold.json 2> /dev/null) )
[ $verbose ] && echo "funcJsonList:"
[ $verbose ] && printf "%s\n" ${funcJsonList[@]}
for jsonFile in ${funcJsonList[@]}
do
    add_numberofvols ${jsonFile}
done

## For the fieldmap runs, add the IntendedFor field:
#
# We will get two lists of json files: one for the fmaps and one for the other
#  images in the session.
# We'll loop through the fmap json list and, for each one, we'll find which
#  other images in the session have the same acquisition parameters (shim settings,
#  image dimensions and voxel dimensions).  Those that match are added to the
#  IntendedFor list and removed from the list of non-fmap json files in the session
#  (since they have already assigned to a fmap).  After finishing with all the non-
#  fmap images in the session, we go back to the fmap json file list, and find any
#  other fmap json files of the same acquisition type and run number (because fmaps
#  have several files: normal- and reversed-polarity, or magnitude and phase, etc.)
#  We add the same IntendedFor list to those other corresponding fmap json files, and
#  remove them from the list of available fmap json files.
#  Once we have gone through all the fmap json files, we are done.
#

echo "Adding 'IntendedFor' to the fieldmap runs in ${session}"

# Check if we are in a Session sub-folder for a subject:
sesBasename=$(basename ${session})
if [ ${sesBasename#ses-} == ${sesBasename} ]
then
    subString="${session}/"    # the subject string is all the session
else
    subString="${session%$sesBasename}"  # subject string is the session variable w/o the "ses-XXXX" string
fi
[ $verbose ] && echo "subject string: $subString"

# Get a list of all fmap json files in the session:
fmapFolder=${session}/fmap
fmapJsonList=( $(ls ${fmapFolder}/*.json 2> /dev/null) )
# Exclude filenames with *_rec-phase_* in it:
fmapJsonList=( $(printf "%s\n" ${fmapJsonList[@]} | grep -v "_rec-phase_") )
[ $verbose ] && echo "fmapJsonList:"
[ $verbose ] && printf "%s\n" ${fmapJsonList[@]}

# Get a list of all json files in the session, except for the fmap folder.
sessionJsonList=( $(ls ${session}/*/*.json 2> /dev/null | grep -v ${fmapFolder} ) )
# # Also, exclude all the *_SBRef files:
# sessionJsonList=( $(printf "%s\n" ${sessionJsonList[@]} | grep -v "_sbref.json" ) )
[ $verbose ] && echo ""
[ $verbose ] && echo "sessionJsonList:"
[ $verbose ] && printf "%s\n" ${sessionJsonList[@]}

paramName=ShimSetting
  
# Loop through all fmap json files:
fmapJFindex=0
while [ ${fmapJFindex} -lt ${#fmapJsonList[@]} ]
do
{
    thisFMap="${fmapJsonList[$fmapJFindex]}"
    [ $verbose ] && echo ""
    [ $verbose ] && echo "fmapJFindex: $fmapJFindex; thisFMap: ${thisFMap}"
    # If not empty:
    if [ ! "x${thisFMap}" == "x" ]
    then
    {
        # Get ShimSetting and image dimensions/resolution
	fmapShims=$(read_header_param ${paramName} ${thisFMap})
	fmapDims=$(get_json_dims_etc ${thisFMap})
	[ $verbose ] && echo "fmapShims: ${fmapShims[@]}"
	[ $verbose ] && echo "fmapDims: ${fmapDims[@]}"

    	# Initialize list of json files to be added to the fmap json to empty.
    	unset toBeAddedList
	[ $verbose ] && echo "To-be-added list:"
	i=0
	# Loop through the list of session json files:
	sessionJFindex=0
	while [ ${sessionJFindex} -lt ${#sessionJsonList[@]} ]
     	do
	{
    	    thisImage="${sessionJsonList[$sessionJFindex]}"
	    # If not empty:
    	    if [ ! "x${thisImage}" == "x" ]
	    then
    	    {
	        # Get ShimSetting and image dimensions/resolution
		imageShims=$(read_header_param ${paramName} ${thisImage})
		imageDims=$(get_json_dims_etc ${thisImage})

	    	# If they match those of the fmap json file:
		if [ "${imageShims}" == "${fmapShims}" ] && \
		   [ "${imageDims}" == "${fmapDims}" ]
		then
		{
	            # Add the corresponding nifti file to the list of files
		    # to be added to fmap json:
		    # (We need the path relative to the subject level)
		    hola=( $(ls ${thisImage%.json}.nii*) )
		    toBeAddedList[$i]="${hola#${subString}}"
		    [ $verbose ] && echo "    $i: ${toBeAddedList[$i]}"
		    let i+=1
		    # remove it from the list of all json files in the session
		    #   (so we don't add it to a second fmap json):
		    sessionJsonList[$sessionJFindex]=""
		}
		fi
	    }
	    fi
	    let sessionJFindex+=1
	}
	done

    	# If the list of json files to be added is not empty:
	#   (we just need to check whether "i" is greater than 0):
	if [ "$i" -gt 0 ]
	then
	{
	    # get the acquisition for this fmap:
	    fmapAcqAndRun=$(get_acq_and_run ${thisFMap})

            # Loop through all the fmap json files that have the same _acq- and _run-:
            j=0
	    while [ ${j} -lt ${#fmapJsonList[@]} ]
	    do
	    {
    	        fm="${fmapJsonList[$j]}"
		[ $verbose ] && echo ""
		[ $verbose ] && echo "   j: $j; fm: ${fm}"
		# If not empty:
		if [ ! "x${fm}" == "x" ]
    		then
	        {
		    # Check that it has the same acquisition type and run number as ${thisFMap}:
		    # (they will differ in the "dir-")
		    fmAcqAndRun=$(get_acq_and_run ${fm})
		    if [ "$fmAcqAndRun" == "$fmapAcqAndRun" ]
		    then
		    {
			# Check that it indeed has the same ShimSetting and dimensions/resolution
             		#   (this is trivial for the initial one, but not for others with the same _acq-
             		#    and _run-):
			shims=$(read_header_param ${paramName} ${fm})
			dims=$(get_json_dims_etc ${fm})
			if [ "${shims}" == "${fmapShims}" ] && \
		            [ "${dims}" == "${fmapDims}" ]
			then
			{
			    # If they are the same, Add the list of json
              	      	    #    files to the IntendedFor of the fmap json
			    [ $verbose ] && echo "    IntendedFor:"
			    [ $verbose ] && printf "    %s\n" ${toBeAddedList[@]}
			    add_intendedfor ${fm} ${toBeAddedList[@]}

			    # remove that fmap json file from the list of fmap json files
			    fmapJsonList[$j]=""
			}
			fi
		    }
		    fi
    	        }
		fi
		let j+=1
	    }
	    done
	}
	fi
    }
    fi

    let fmapJFindex+=1
}
done

## For all the task json files, fix the "CogAtlasID" field:
#   Checks the json file to see if the key "CogAtlasID" value is "TODO" (bug in heudiconv)
#   If that it the case, it sets it to "doi:TODO" so that it's BIDS compliant.
echo "Fixing task json files in ${session}"

bidsFolder=${session%/sub-*}

# To be able to run "find" you need to cd to a place where we have access,
# and it is possible that the call to "completeJSONs" is done from a place
# from which we don't have access
cd /tmp
find ${bidsFolder} -type f -name "task-*.json" \
     -exec sed -i -e 's/"CogAtlasID": "TODO",/"CogAtlasID": "doi:TODO",/' {} +
