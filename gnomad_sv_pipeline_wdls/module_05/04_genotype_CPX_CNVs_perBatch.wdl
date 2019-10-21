# Copyright (c) 2018 Talkowski Lab

# Contact Ryan Collins <rlcollins@g.harvard.edu>

# Distributed under terms of the MIT License


# Workflow to perform depth-based genotyping per batch
# on predicted CPX CNVs from 04b

workflow genotype_CPX_CNVs_perBatch {
  File cpx_bed
  File RD_depth_sepcutoff
  Int n_per_split_small
  Int n_per_split_large
  Int n_RdTest_bins
  String batch
  File medianfile
  File famfile
  File svc_acct_key
  File sampleslist
  String coveragefile
  File coveragefile_idx

  Array[String] samples = read_lines(sampleslist)

  call shard_bed {
    input:
      bed=cpx_bed,
      n_per_split_small=n_per_split_small,
      n_per_split_large=n_per_split_large,
      sampleslist=sampleslist
  }

  scatter (lt5kb_bed in shard_bed.lt5kb_beds) {
    call RdTest_genotype as RD_genotype_lt5kb {
      input:
        bed=lt5kb_bed,
        coveragefile=coveragefile,
        coveragefile_idx=coveragefile_idx,
        svc_acct_key=svc_acct_key,
        medianfile=medianfile,
        famfile=famfile,
        samples=samples,
        gt_cutoffs=RD_depth_sepcutoff,
        n_bins=n_RdTest_bins,
        prefix=basename(lt5kb_bed, ".bed")
    }
  }
  
  scatter (gt5kb_bed in shard_bed.gt5kb_beds) {
    call RdTest_genotype as RD_genotype_gt5kb {
      input:
        bed=gt5kb_bed,
        coveragefile=coveragefile,
        coveragefile_idx=coveragefile_idx,
        svc_acct_key=svc_acct_key,
        medianfile=medianfile,
        famfile=famfile,
        samples=samples,
        gt_cutoffs=RD_depth_sepcutoff,
        n_bins=n_RdTest_bins,
        prefix=basename(gt5kb_bed)
    }
  }

  call concat_melted_genotypes {
    input:
      lt5kb_genos=RD_genotype_lt5kb.melted_genotypes,
      gt5kb_genos=RD_genotype_gt5kb.melted_genotypes,
      batch=batch
  }

  output {
    File genotypes = concat_melted_genotypes.genotypes
  }
}

task shard_bed {
  File bed
  Int n_per_split_small
  Int n_per_split_large
  File sampleslist

  command <<<
    set -euo pipefail
    if [ $( zcat ${bed} | fgrep -v "#" | wc -l ) -gt 0 ]; then
      #First, repace samples in input bed with full list of all samples in batch
      zcat ${bed} \
        | fgrep -v "#" \
        | awk -v OFS="\t" -v samples=$( cat ${sampleslist} | paste -s -d, ) \
          '{ print $1, $2, $3, $4, samples, "DUP" }' \
        | sort -Vk1,1 -k2,2n -k3,3n \
        | bgzip -c \
        > newBed_wSamples.bed.gz || true
      #Second, split by small vs large CNVs
      zcat newBed_wSamples.bed.gz \
        | awk -v OFS="\t" '($3-$2<5000) {print $0}' \
        | split -l ${n_per_split_small} -a 6 - lt5kb. || true
      zcat newBed_wSamples.bed.gz \
        | awk -v OFS="\t" '($3-$2>=5000) {print $0}' \
        | split -l ${n_per_split_large} -a 6 - gt5kb. || true
    fi
    if [ $( find ./ -name "lt5kb.*" | wc -l ) -eq 0 ]; then
      touch lt5kb.aaaaaa
    fi
    if [ $( find ./ -name "gt5kb.*" | wc -l ) -eq 0 ]; then
      touch gt5kb.aaaaaa
    fi
  >>>

  output {
    Array[File] lt5kb_beds = glob("lt5kb.*")
    Array[File] gt5kb_beds = glob("gt5kb.*")
  }
    
  runtime {
    preemptible: 3
    maxRetries: 1
    docker: "talkowski/sv-pipeline@sha256:5ff4bd3264cc61fc69e37cd2e307e3b5ab8458fec2606e1b57d4b1f73fecead0"
    disks: "local-disk 50 HDD"
  }
}


# Run depth-based genotyping
task RdTest_genotype {
  File bed
  String coveragefile
  File medianfile
  File svc_acct_key
  File coveragefile_idx
  File famfile
  Array[String] samples
  File gt_cutoffs
  Int n_bins
  String prefix

  command <<<
    set -euo pipefail
    /opt/RdTest/localize_bincov.sh \
      ${bed} \
      ${coveragefile} \
      ${coveragefile_idx} \
      ${svc_acct_key};
    Rscript /opt/RdTest/RdTest.R \
      -b ${bed} \
      -c local_coverage.bed.gz \
      -m ${medianfile} \
      -f ${famfile} \
      -n ${prefix} \
      -w ${write_tsv(samples)} \
      -i ${n_bins} \
      -r ${gt_cutoffs} \
      -y /opt/RdTest/bin_exclude.bed.gz \
      -g TRUE;
    /opt/sv-pipeline/04_variant_resolution/scripts/merge_RdTest_genotypes.py \
      ${prefix}.geno \
      ${prefix}.gq \
      rd.geno.cnv.bed;
    sort -k1,1V -k2,2n rd.geno.cnv.bed | uniq | bgzip -c > rd.geno.cnv.bed.gz
  >>>

  output {
    # File genotypes = "${prefix}.geno"
    # File copy_states = "${prefix}.median_geno"
    # File metrics = "${prefix}.metrics"
    # File gq = "${prefix}.gq"
    # File varGQ = "${prefix}.vargq"
    File melted_genotypes = "rd.geno.cnv.bed.gz"
  }

  runtime {
    preemptible: 3
    docker: "talkowski/sv-pipeline-rdtest@sha256:0393ca5260e523f8646a72a2a739863384de73670383d3f0b32c6ccceba010e8"
    disks: "local-disk 100 HDD"
    bootDiskSizeGb: "30"
    memory: "8 GB"
    maxRetries: 1
  }
}


# Merge melted genotype files
task concat_melted_genotypes {
  Array[File] lt5kb_genos
  Array[File] gt5kb_genos
  String batch

  command <<<
    zcat ${sep=' ' lt5kb_genos} ${sep=' ' gt5kb_genos} \
      | sort -Vk1,1 -k2,2n -k3,3n \
      | bgzip -c \
      > ${batch}.rd_genos.bed.gz
  >>>

  output {
    File genotypes = "${batch}.rd_genos.bed.gz"
  }
  
  runtime {
    docker: "talkowski/sv-pipeline@sha256:5ff4bd3264cc61fc69e37cd2e307e3b5ab8458fec2606e1b57d4b1f73fecead0"
    preemptible: 3
    maxRetries: 1
    memory: "16 GB"
    disks: "local-disk 250 HDD"
  }
}