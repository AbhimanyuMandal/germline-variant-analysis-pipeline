#!/bin/bash

################################################################################
# Sequencing Depth Metrics
#
# Description
#
# Calculate average sequencing depth across filtered variant files.
#
################################################################################

total_depth=0
count=0

for file in *vqsr.vcf;
do
        echo "Processing $file"

        #Extract depth information and sum it up
        file_depth=$(bcftools query -f '%DP\n' $file | awk '{sum+=$1; cnt++} END {print sum}')
    file_count=$(bcftools query -f '%DP\n' $file | wc -l)

    # Add to total
    total_depth=$((total_depth + file_depth))
    count=$((count + file_count))
done

# Calculate mean depth
mean_depth=$(echo "scale=2; $total_depth / $count" | bc)

echo "Total depth: $total_depth"
echo "Total count: $count"
echo "Mean depth: $mean_depth"

echo "Pipeline completed successfully."