#!/bin/bash

# Script to cleanup temporary files in the output of the HCP Pipelines v3.4,
#   by removing files that are easily re-generated if needed.
#
#   1) Remove total warp matrices (concatenation of gradient distortion correction
#      warps, susceptibility distortion correction and motion).
#   2) Creates a script that can be run to generate them again, if needed.
#
# Input:
#
#   Folder to be processed

myDir=$1

###   Cleaning up   ###

echo "Cleaning up warp fields"

# loop through all runs in all tasks:
funcRunsList=( $(ls -d --ignore=T?w --ignore=MNINonLinear --ignore=pipelines_logs ${myDir}/*/*_run-* 2> /dev/null) )
for funcRun in ${funcRunsList[@]}
do
    # Clean up the total warp matrices
    # (they can be later recreated):
    rm -f ${funcRun}/MotionMatrices/MAT*_gdc_warp.nii*
    rm -f ${funcRun}/MotionMatrices/MAT*_all_warp.nii*
done 


echo "Cleaning up individual volumes"

# loop through all runs in all tasks:
funcRunsList=( $(ls -d --ignore=T?w --ignore=MNINonLinear --ignore=pipelines_logs ${myDir}/*/*_run-* 2> /dev/null) )
for funcRun in ${funcRunsList[@]}
do
    # Clean up the individual volumes that were used to do the
    # one step transformation:
    # (there are really not needed at all)
    rm -fr ${funcRun}/OneStepResampling/prevols
    rm -fr ${funcRun}/OneStepResampling/postvols
done 


###   Generate scripts to recover matrices   ###

echo "Generating scripts to recover matrices"

# We'll create a script for each functional run, in case the user
#   just wants to re-create the matrices for a single run:

for funcRun in ${funcRunsList[@]}
do
    scriptFile=${funcRun}/MotionMatrices/recreate_warp_matrices.sh
    echo "#\!/bin/bash" > ${scriptFile}
    echo "#"                                               >> ${scriptFile}
    echo "# Script to re-create the total warp matrices. " >> ${scriptFile}
    echo "# To execute, just run:"                         >> ${scriptFile}
    echo "#     . ${scriptFile}"                           >> ${scriptFile}
    echo ""                                                >> ${scriptFile}
    echo "# check if FSL has been configured:"             >> ${scriptFile}
    echo "if [ -z \"\$FSLOUTPUTTYPE\" ]; then"             >> ${scriptFile}
    echo "    . \${FSLDIR}/etc/fslconf/fsl.sh"             >> ${scriptFile}
    echo "fi"                                              >> ${scriptFile}
    echo "myDir=\"${myDir}\""                              >> ${scriptFile}
    echo "funcRun=\"\${myDir}${funcRun#$myDir}\""          >> ${scriptFile}
    echo ""                                                >> ${scriptFile}
    echo "task=\"$(basename ${funcRun%/*/})\""             >> ${scriptFile}
    echo "T1wImageFile=\`ls \${funcRun}/OneStepResampling/T1w_restore.*.nii*\`" >> ${scriptFile}
    echo "OutputTransform=\${myDir}/MNINonLinear/xfms/\${task}2standard"      >> ${scriptFile}
    echo "# loop through the volumes:"                                        >> ${scriptFile}
    echo "for v in \`ls \${funcRun}/MotionMatrices/MAT_????\`; do"            >> ${scriptFile}
    echo "  \${FSLDIR}/bin/convertwarp --relout --rel \\"                     >> ${scriptFile}
    echo "    --ref=\${funcRun}/OneStepResampling/prevols/vol\${v##*MAT_} \\" >> ${scriptFile}
    echo "    --warp1=\${funcRun}/\${task}_gdc_warp \\"                       >> ${scriptFile}
    echo "    --postmat=\${v} \\"                                             >> ${scriptFile}
    echo "    --out=\${v}_gdc_warp.nii.gz"                                    >> ${scriptFile}
    echo "  \${FSLDIR}/bin/convertwarp --relout --rel \\"                     >> ${scriptFile}
    echo "    --ref=\${T1wImageFile} \\"                                      >> ${scriptFile}
    echo "    --warp1=\${v}_gdc_warp \\"                                      >> ${scriptFile}
    echo "    --warp2=\${OutputTransform} \\"                                 >> ${scriptFile}
    echo "    --out=\${v}_all_warp.nii.gz"                                    >> ${scriptFile}
    echo "done"                                                               >> ${scriptFile}
done
