library(vcfR)
library(futile.logger)

flog.threshold(DEBUG)

source("R/data_parsing.R")
source("R/filters.R")
source("R/preprocessing.R")

set.seed(10)

vcf_filename <- "../amiss_data/clinvar_20190624.vep.vcf"
cadd_snv_filename <- "../amiss_data/CADD_clingen.tsv"
cadd_indel_filename <- "../amiss_data/CADD_clingen_indel.tsv"

if (!file.exists(vcf_filename))
  stop(paste("Input VCF file", vcf_filename, "does not exist. Stopping."))
if (!file.exists(cadd_snv_filename))
  stop(paste("Input CADD SNV annotation file", cadd_snv_filename, "does not exist. Stopping."))
if (!file.exists(cadd_indel_filename))
  stop(paste("Input CADD indel annotation file", cadd_indel_filename, "does not exist. Stopping."))

vcf <- vcfR::read.vcfR(vcf_filename)

vcf_df <- vcf_object_to_dataframe(vcf, num_batches = 100, info_filters = c(clingen), vep_filters = c(canonical))
vcf_df <- vcf_df[vcf_df$CLNSIG != "drug_response", ]

stopifnot(all(vcf_df$Feature == vcf_df$Ensembl_transcriptid, na.rm = TRUE))

write.csv(vcf_df, "full_clingen.csv")

cadd_snv_data <- read.delim(cadd_snv_filename, skip = 1, as.is = TRUE)
cadd_indel_data <- read.delim(cadd_indel_filename, skip = 1, as.is = TRUE)

stopifnot(colnames(cadd_snv_data) == colnames(cadd_indel_data))

cadd_data <- rbind(cadd_snv_data, cadd_indel_data)

merged_data <- merge(x = cadd_data,
                     y = vcf_df,
                     all = FALSE,
                     by.x = c("X.Chrom", "Pos", "Ref", "Alt", "FeatureID"),
                     by.y = c("CHROM", "POS", "REF", "ALT", "Feature"))

write.csv(file = "merged_data.csv", x = merged_data, row.names = FALSE)
