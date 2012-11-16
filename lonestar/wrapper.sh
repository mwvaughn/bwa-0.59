tar -xzf bin.tgz
export PATH=$HOME/bin:$PATH:./bin

#query1=/vaughn/sample.fq
#databaseFasta=/shared/iplantcollaborative/genomeservices/builds/0.1/Arabidopsis_thaliana/Col-0_thale_cress/10/de_support/genome.fas

# SPLIT_COUNT / 4 = number of records per BWA job
SPLIT_COUNT=16000000

OUTPUT_SAM=bwa_output.sam

# Vars passed in from outside
REFERENCE=${databaseFasta}
QUERY1=${query1}
QUERY2=${query2}
CPUS=${IPLANT_CORES_REQUESTED}

ARGS="-t 12"
if [ -n "${mismatchTolerance}" ]; then ARGS="${ARGS} -n ${mismatchTolerance}"; fi
if [ -n "${maxGapOpens}" ]; then ARGS="${ARGS} -o ${maxGapOpens}"; fi
if [ -n "${maxGapExtensions}" ]; then ARGS="${ARGS} -e ${maxGapExtensions}"; fi
if [ -n "${noEndIndel}" ]; then ARGS="${ARGS} -i ${noEndIndel}"; fi
if [ -n "${maxOccLongDeletion}" ]; then ARGS="${ARGS} -d ${maxOccLongDeletion}"; fi
if [ -n "${seedLength}" ]; then ARGS="${ARGS} -l ${seedLength}"; fi
if [ -n "${maxDifferenceSeed}" ]; then ARGS="${ARGS} -k ${maxDifferenceSeed}"; fi
if [ -n "${maxEntriesQueue}" ]; then ARGS="${ARGS} -m ${maxEntriesQueue}"; fi
#if [ -n "${numThreads}" ]; then ARGS="${ARGS} -t ${numThreads}"; fi
if [ -n "${mismatchPenalty}" ]; then ARGS="${ARGS} -M ${mismatchPenalty}"; fi
if [ -n "${gapOpenPenalty}" ]; then ARGS="${ARGS} -O ${gapOpenPenalty}"; fi
if [ -n "${gapExtensionPenalty}" ]; then ARGS="${ARGS} -E ${gapExtensionPenalty}"; fi
if [ -n "${stopSearching}" ]; then ARGS="${ARGS} -R ${stopSearching}"; fi
if [ -n "${qualityForTrimming}" ]; then ARGS="${ARGS} -q ${qualityForTrimming}"; fi
if [ -n "${barCodeLength}" ]; then ARGS="${ARGS} -B ${barCodeLength}"; fi

if [ "${logScaleGapPenalty}" -eq "1" ]; then ARGS="${ARGS} -L"; fi
if [ "${nonIterativeMode}" -eq "1" ]; then ARGS="${ARGS} -N"; fi

# Determine pair-end or not
IS_PAIRED=0
if [[ -n "$QUERY1" && -n "$QUERY2" ]]; then let IS_PAIRED=1; echo "Paired-end"; fi

# Assume script is already running in a scratch directory
# Create subdirectories for BWA workflow
for I in input1 input2 temp
do
	echo "Creating $I"
	mkdir -p $I
done

# Copy reference sequence...
REFERENCE_F=$(basename ${REFERENCE})
echo "Copying $REFERENCE_F"
iget_cached -frPVT  ${REFERENCE} .
# Quick sanity check before committing to do anything compute intensive
if ! [[ -e $REFERENCE_F ]]; then echo "Error: Genome sequence not found."; exit 1; fi

# Copy sequences
QUERY1_F=$(basename ${QUERY1})
echo "Copying $QUERY1_F"
iget_cached -frPVT ${QUERY1} .
split -l $SPLIT_COUNT --numeric-suffixes $QUERY1_F input1/query.

if [[ "$IS_PAIRED" -eq 1 ]];
then
	QUERY2_F=$(basename ${QUERY2})
	echo "Copying $QUERY2_F"
	iget_cached -frPVT ${QUERY2} .
	split -l $SPLIT_COUNT --numeric-suffixes $QUERY2_F input2/query.
fi

# Copying the indexes in addition to the FASTA file
echo "Copying $REFERENCE_F index"
CHECKSUM=0
for J in amb ann bwt fai pac rbwt rpac rsa sa
do
	echo "Copying ${REFERENCE}.${J}"
	iget_cached -frPVT "${REFERENCE}.${J}" . && let "CHECKSUM += 1" || { echo "${REFERENCE}.${J} was not fetched"; }
done

# If counter < 9, this means one of the index files was not transferred.
# Solution: Re-index the genome sequence
if (( $CHECKSUM < 9 )); then
	echo "Indexing $REFERENCE_F"
	bin/bwa index -a bwtsw $REFERENCE_F
fi

# Align using the parametric launcher
# Create paramlist for initial alignment + SAI->SAM conversion
# Emit one cli if single-end, another if pair end
rm -rf paramlist.aln
for C in input1/*
do
	ROOT=$(basename $C);
	if [ "$IS_PAIRED" -eq 1 ]; then
		echo "bin/bwa aln ${ARGS} $REFERENCE_F input1/$ROOT > temp/$ROOT.1.sai ; bin/bwa aln ${ARGS} $REFERENCE_F input2/$ROOT > temp/$ROOT.2.sai ; bin/bwa sampe $REFERENCE_F temp/$ROOT.1.sai temp/$ROOT.2.sai input1/$ROOT input2/$ROOT > temp/${ROOT}.sam" >> paramlist.aln
	else
		echo "bin/bwa aln ${ARGS} $REFERENCE_F input1/$ROOT > temp/$ROOT.1.sai ; bin/bwa samse $REFERENCE_F temp/$ROOT.1.sai input1/$ROOT > temp/${ROOT}.sam" >> paramlist.aln
	fi
done

echo "Launcher...."
date
EXECUTABLE=$TACC_LAUNCHER_DIR/init_launcher
$TACC_LAUNCHER_DIR/paramrun $EXECUTABLE paramlist.aln
date
echo "..Done"

echo "Post-processing...."
# Extract header from one SAM file
head -n 120000 temp/query.01.sam | egrep "^@" > $OUTPUT_SAM
# Extract non-header files from all SAM files
for D in temp/*sam
do
	egrep -v -h "^@" $D >> $OUTPUT_SAM
done

# Clean up temp data. If not, service will copy it all back
for M in $QUERY1_F $QUERY2_F $REFERENCE_F $REFERENCE_F.* input1 input2 temp .launcher
do
	echo "Cleaning $M"
	rm -rf $M
done

# Remove bin directory
rm -rf bin

# This is needed for large return files until Rion is able to update the service to add -T automatically
shopt -s expand_aliases
alias iput='iput -T'

