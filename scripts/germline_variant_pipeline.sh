#!/bin/bash

################################################################################
# Germline Variant Analysis Pipeline
#
# Description
#
# Performs:
#
# • Read alignment
# • BAM processing
# • Germline variant calling
# • Variant filtering
# • Variant annotation
#
# Tools
#
# BWA-MEM
# SAMtools
# Picard
# GATK
# VEP
#
################################################################################

################################################################################
# NOTE
#
# This pipeline was developed in a Linux HPC environment.
#
# Software installation paths and reference genome locations should be
# modified according to your local system before execution.
################################################################################

#The first half includes data pre-processing - bamtofastq, BWA alignment, Marking Duplicates, BQSR
##The second half includes identifying SNPs and indels - Haplotypecaller, GenotypeGVCFs, Variant Annotator, VQSR
###After identifying the variants, they are further annotated and filtered using Variant Effect Predictor (VEP) tool

#defining variables################################################################################

bwa=/opt/lib/bwa-mem2/bwa-mem2
bwa_index=/opt/ref-genomes/human_genome_bwa-mem2/hg38_v0_Homo_sapiens_assembly38.fasta
bamtofastq=/opt/lib/biobambam2-2.0.180/bin/bamtofastq
samtools_index_hg=/opt/ref-genomes/human_genome_samtools_index/hg38_v0_Homo_sapiens_assembly38.fasta
samtools=/opt/anaconda3/bin/samtools
ANNOVAR=/opt/lib/annovar
PICARD=/opt/lib/picard/picard.jar
GATK=/opt/lib/gatk-4.2.2.0/gatk
ref_vcf=/opt/ref-genomes/GATK-hg38/
vep=/mnt/10TB/VEP110/ensembl-vep/vep
filter_vep=/mnt/10TB/VEP110/ensembl-vep/filter_vep
vep_cache=/mnt/10TB/VEP110/vep_cache/

#Extracting fastq from input#######################################################################
for x in $(awk 'BEGIN {FS="\t"}; NR>0 && NR<63 {print $1}' list.txt);
do
$bamtofastq collate=1 exclude=QCFAIL,SECONDARY,SUPPLEMENTARY \
filename=$x gz=0 level=5 outputperreadgroup=1 \
outputperreadgroupprefix=${x%.*} inputformat=bam

#BWA alignment#####################################################################################
$bwa mem -t 12 $bwa_index ${x%.*}'_1_1.fq' \
${x%.*}'_1_2.fq' | $samtools view -bh -o ${x%.*}'_aligned.bam'

#Sorting and indexing of the aligned BAM file######################################################
$samtools sort --threads 12 -m 1G -l 9 ${x%.*}'_aligned.bam' \
-o ${x%.*}'_aligned_sorted.bam'

#Marking duplicates using PICARD###################################################################
java -jar $PICARD MarkDuplicates \
-I ${x%.*}'_aligned_sorted.bam' \
-O ${x%.*}'_duplicate_marked.bam' \
-M ${x%.*}'_duplicate_marked.txt'

java -jar $PICARD AddOrReplaceReadGroups \
-I ${x%.*}'_duplicate_marked.bam' \
-O ${x%.*}'_duplicate_marked.RG.bam' -RGID ${x%.*} \
-RGLB L1 -RGPL ILLUMINA -RGPU unit1 -RGSM ${x%.*}

#Base Quality Score Recalibrator###################################################################
$GATK BaseRecalibrator \
-I ${x%.*}'_duplicate_marked.RG.bam' \
-R $samtools_index_hg \
  --known-sites /opt/ref-genomes/GATK-hg38/CosmicCodingMuts_chr_M_sorted.vcf \
  --known-sites /opt/ref-genomes/GATK-hg38/hg38_v0_Homo_sapiens_assembly38.dbsnp138.vcf \
  --known-sites /opt/ref-genomes/GATK-hg38/hg38_v0_1000G_omni2.5.hg38.vcf \
  --known-sites /opt/ref-genomes/GATK-hg38/hg38_v0_Homo_sapiens_assembly38.known_indels.vcf \
  --known-sites /opt/ref-genomes/GATK-hg38/hg38_v0_Mills_and_1000G_gold_standard.indels.hg38.vcf \
-O ${x%.*}'_base_recal.table'

$GATK ApplyBQSR \
-R $samtools_index_hg \
-I ${x%.*}'_duplicate_marked.RG.bam' \
  --bqsr-recal-file ${x%.*}'_base_recal.table' \
-O ${x%.*}'_base_recal.bam'

#Indexing of the bam files after pre-processing#####################################################
samtools index -M *_base_recal.bam

#Calling SNPs and variants simultaneously using HaplotypeCaller#####################################
$GATK HaplotypeCaller \
-R $samtools_index_hg \
-I ${x%.*}'_base_recal.bam' \
-O ${x%.*}'_base_recal.vcf.gz' \
-ERC GVCF

#Joint genotyping of the variants###################################################################
$GATK GenotypeGVCFs \
-R $samtools_index_hg \
-V ${x%.*}'_base_recal.vcf.gz' \
-O ${x%.*}'_base_recal_genotype.vcf.gz'

#Annotate a VCF with dbSNP IDs and depth of coverage for each sample################################
$GATK VariantAnnotator \
 -R $samtools_index_hg \
 -I ${x%.*}'_base_recal.bam' \
 -V ${x%.*}'_base_recal_genotype.vcf.gz' \
 -O ${x%.*}'_base_recal_output.vcf.gz'

#Variant Quality Score Recalibration ###############################################################
$GATK VariantRecalibrator \
-R $samtools_index_hg \
-V ${x%.*}'_base_recal_output.vcf.gz' \
-resource:hapmap,known=false,training=true,truth=true,prior=15.0 /mnt/swift/abhimanyu/Germline-mutations/check/hapmap_3.3.hg38.vcf.gz \
-resource:1000G,known=false,training=true,truth=false,prior=10.0 /mnt/swift/abhimanyu/Germline-mutations/check/1000G_phase1.snps.high_confidence.hg38.vcf.gz \
-resource:omni,known=false,training=true,truth=true,prior=12.0 /mnt/swift/abhimanyu/Germline-mutations/check/1000G_omni2.5.hg38.vcf.gz \
-resource:dbsnp,known=true,training=false,truth=false,prior=2.0 /mnt/swift/abhimanyu/Germline-mutations/check/Homo_sapiens_assembly38.dbsnp138.vcf.gz \
-an QD -an MQ -an MQRankSum -an ReadPosRankSum -an FS -an SOR -mode SNP \
-O ${x%.*}'_output.recal' --tranches-file ${x%.*}'_output.tranches' --rscript-file ${x%.*}'_output.plots.R'

$GATK ApplyVQSR \
-R $samtools_index_hg \
-V ${x%.*}'_base_recal_output.vcf.gz' \
-O ${x%.*}'_output_vqsr.vcf.gz' --recal-file ${x%.*}'_output.recal' -mode SNP

#Unzip the files for Variant Annotation using VEP###################################################
gunzip ${x%.*}'_output_vqsr.vcf.gz'

#Annotation of the variants using VEP(Variant Effect Predictor)#####################################
$vep --cache --dir_cache $vep_cache \
--input_file ${x%.*}'_output_vqsr.vcf' \
--output_file ${x%.*}'_vep.vcf' \
--failed 1 --format vcf --vcf --offline --everything

#Filtering the variants based on population allele frequency, IMPACT, SIFT and Polyphen outcomes
$filter_vep \
--input_file ${x%.*}'_vep.vcf' \
--output_file ${x%.*}'_vep_filter.vcf' \
--filter "(MAX_AF < 0.001 or not MAX_AF) and ((IMPACT is HIGH) or (IMPACT is MODERATE and (SIFT match deleterious or PolyPhen match damaging)))"

#Filtering the variants that are of low quality.
$filter_vep \
--input_file ${x%.*}'_vep_filter.vcf' \
--output_file ${x%.*}'_vep_filter_PASS.vcf' \
--filter "FILTER is PASS"
done

for x in $(awk 'BEGIN {FS="\t"}; NR>0 && NR<63 {print $1}' list.txt);
do
perl vcf2maf.pl \
--input-vcf ${x%.*} _vep_filter_PASS.vcf' \
--output-maf ${x%.*} _vep_filter_PASS.maf \
--vep-path /mnt/10TB/VEP110/ensembl-vep/vep \
--ref-fasta $bwa_index

echo "Pipeline completed successfully."
