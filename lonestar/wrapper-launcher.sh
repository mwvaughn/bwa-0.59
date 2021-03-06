#query1=/vaughn/sample.fq
#databaseFasta=/shared/iplantcollaborative/genomeservices/builds/0.1/Arabidopsis_thaliana/Col-0_thale_cress/10/de_support/genome.fas

OUTPUT_SAM=bwa_output.sam

# Vars passed in from outside
REFERENCE=${databaseFasta}
QUERY1=${query1}
QUERY2=${query2}
CPUS=${IPLANT_CORES_REQUESTED}

ARGS=
if [ -n "${mismatchTolerance}" ]; then ARGS="${ARGS} -n ${mismatchTolerance}"; fi
if [ -n "${maxGapOpens}" ]; then ARGS="${ARGS} -o ${maxGapOpens}"; fi
if [ -n "${maxGapExtensions}" ]; then ARGS="${ARGS} -e ${maxGapExtensions}"; fi
if [ -n "${noEndIndel}" ]; then ARGS="${ARGS} -i ${noEndIndel}"; fi
if [ -n "${maxOccLongDeletion}" ]; then ARGS="${ARGS} -d ${maxOccLongDeletion}"; fi
if [ -n "${seedLength}" ]; then ARGS="${ARGS} -l ${seedLength}"; fi
if [ -n "${maxDifferenceSeed}" ]; then ARGS="${ARGS} -k ${maxDifferenceSeed}"; fi
if [ -n "${maxEntriesQueue}" ]; then ARGS="${ARGS} -m ${maxEntriesQueue}"; fi
if [ -n "${numThreads}" ]; then ARGS="${ARGS} -t ${numThreads}"; fi
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
iget -fT ${REFERENCE} .
# Quick sanity check before committing to do anything compute intensive
if ! [[ -e $REFERENCE_F ]]; then echo "Error: Genome sequence not found."; exit 1; fi

# Copy sequences
QUERY1_F=$(basename ${QUERY1})
echo "Copying $QUERY1_F"
iget -frPVT ${QUERY1} .
perl splitfastq.pl -f $QUERY1_F -o input1 -n ${CPUS}

if [[ "$IS_PAIRED" -eq 1 ]];
then
	QUERY2_F=$(basename ${QUERY2})
	echo "Copying $QUERY2_F"
	iget -frPVT ${QUERY2} .
	perl splitfastq.pl -f $QUERY2_F -o input2 -n ${CPUS}
fi

# Copying the indexes in addition to the FASTA file
echo "Copying $REFERENCE_F index"
CHECKSUM=0
for J in amb ann bwt fai pac rbwt rpac rsa sa
do
	echo "Copying ${REFERENCE}.${J}"
	iget -frPVT "${REFERENCE}.${J}" . && let "CHECKSUM += 1"|| { echo "${REFERENCE}.${J} was not fetched"; }
done

# If counter < 9, this means one of the index files was not transferred.
# Solution: Re-index the genome sequence
if (( $CHECKSUM < 9 )); then
	echo "Indexing $REFERENCE_F"
	bwa index -a bwtsw $REFERENCE_F
fi

# Align using the parametric launcher
# Create paramlist for initial alignment + SAI->SAM conversion
# Emit one command if single-end, another if pair end
for ((K=1;K<=${CPUS};K++));do

	if [[ $IS_PAIRED == 1 ]]; then
		echo "bwa aln ${ARGS} $REFERENCE_F input1/query.${K} > temp/sai.1.${K} ; bwa aln  ${ARGS} $REFERENCE_F input2/query.${K} > temp/sai.2.${K} ; bwa sampe $REFERENCE_F temp/sai.1.${K} temp/sai.2.${K} input1/query.${K} input2/query.${K} > temp/result.${K}.sam" >> paramlist.aln
	else
		echo "bwa aln ${ARGS} $REFERENCE_F input1/query.${K} > temp/sai.1.${K} ; bwa samse $REFERENCE_F temp/sai.1.${K} input1/query.${K} > temp/result.${K}.sam" >> paramlist.aln
	fi

done

# Get TACC launcher ready...
#module load launcher
echo "Launcher...."
EXECUTABLE=$TACC_LAUNCHER_DIR/init_launcher
$TACC_LAUNCHER_DIR/paramrun $EXECUTABLE paramlist.aln
echo "..Done"

echo "Post-processing...."
# Extract header from one SAM file
head -n 32768 temp/result.1.sam | egrep "^@" > $OUTPUT_SAM
# Extract non-header files from all SAM files
for ((K=1;K<=${CPUS};K++));do
	egrep -v -h "^@"  temp/result.${K}.sam >> $OUTPUT_SAM
done

# Create BAM file from OUTPUT_SAM and index it
# Do I want to use samtools and not Picard?
BAMFILE=$(basename aligned.sam .sam)
BAMFILE="${BAMFILE}.bam"
echo "Creating $BAMFILE"

samtools view -bS $OUTPUT_SAM > $BAMFILE
samtools sort -m 10000000000 $BAMFILE Sorted
mv Sorted.bam $BAMFILE
samtools index $BAMFILE

# Clean up temp data. If not, service will copy it all back
for M in $QUERY1_F $QUERY2_F $REFERENCE_F $REFERENCE_F.* input1 input2 temp 
do
	echo "Cleaning $M"
	rm -rf $M
done
