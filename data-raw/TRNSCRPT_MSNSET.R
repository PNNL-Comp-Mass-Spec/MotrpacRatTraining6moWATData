library(MotrpacRatTraining6moData)
library(dplyr)
library(edgeR)
library(MSnbase)


# Phenodata
p_data <- PHENO %>%
  filter(tissue == "WAT-SC") %>%
  select(pid:viallabel, sex, timepoint = group) %>%
  mutate(sex = factor(stringr::str_to_title(sex),
                      levels = c("Female", "Male")),
         timepoint = ifelse(timepoint == "control", "SED",
                            toupper(timepoint)),
         timepoint = factor(timepoint,
                            levels = c("SED", paste0(2^(0:3), "W"))),
         exp_group = interaction(substr(sex, 1, 1), timepoint, sep = "_")) %>%
  arrange(sex, timepoint) %>%
  mutate(exp_group = factor(exp_group, levels = unique(exp_group)))

# Normalized transcriptomics data
count_mat <- TRNSCRPT_WATSC_RAW_COUNTS %>%
  select(feature_ID, where(is.numeric)) %>%
  tibble::column_to_rownames("feature_ID") %>%
  as.matrix() %>%
  # First round of filtering done in landscape paper
  .[rownames(.) %in% TRNSCRPT_WATSC_NORM_DATA$feature_ID,
    !colnames(.) %in% OUTLIERS$viallabel] # remove 2 outlier samples
# dim(count_mat) # 16764  48

p_data <- p_data[colnames(count_mat), ]

# Remove low-count transcripts
dge <- DGEList(counts = count_mat,
               samples = p_data,
               group = p_data$exp_group)
keep <- filterByExpr(dge)
dge <- dge[keep, , keep.lib.sizes = FALSE]
# Add TMM normalization factors
dge <- calcNormFactors(dge, method = "TMM")

# # Convert to log2 counts-per-million reads
# dge$counts <- cpm(dge, log = TRUE)

# Update count matrix and phenodata
count_mat <- round(dge$counts, digits = 4)
p_data <- select(dge$samples, -group)
# dim(count_mat) # 16443    48

# Add additional columns to phenodata for differential analysis
p_data <- TRNSCRPT_META %>%
  select(viallabel, rin = RIN, pct_globin, pct_umi_dup, median_5_3_bias) %>%
  right_join(p_data, by = "viallabel") %>%
  `rownames<-`(.[["viallabel"]])

# Feature data
f_data <- FEATURE_TO_GENE %>%
  filter(feature_ID %in% rownames(count_mat)) %>%
  select(feature_ID, gene_symbol, entrez_gene) %>%
  distinct() %>%
  # Some transcripts have more than one gene ID
  group_by(feature_ID) %>%
  # For each transcript, remove genes that start with
  # "LOC", "NEWGENE", or "AAB" unless there are no other genes
  filter(!(grepl("^LOC|^NEWGENE|^AAB", gene_symbol) &
             !all(grepl("^LOC|^NEWGENE|^AAB", gene_symbol)))) %>%
  # If all genes start with "LOC", "NEWGENE", or "AAB",
  # only keep those with Entrez IDs unless none of them have Entrez IDs
  filter(!(all(grepl("^LOC|^NEWGENE|^AAB", gene_symbol)) &
             is.na(entrez_gene) & !all(is.na(entrez_gene)))) %>%
  # Collapse duplicates
  summarise(across(c(gene_symbol, entrez_gene),
                   ~ ifelse(all(is.na(.x)), NA_character_,
                            paste(.x, collapse = ";")))) %>%
  as.data.frame() %>%
  `rownames<-`(.[["feature_ID"]]) %>%
  .[rownames(count_mat), ] # reorder features

# How many transcripts have more than one gene? About 1.2%
table(grepl(";", f_data$gene_symbol))
# FALSE  TRUE
# 16273   170

# Create MSnset
TRNSCRPT_MSNSET <- MSnSet(exprs = count_mat, fData = f_data, pData = p_data)

# Save
usethis::use_data(TRNSCRPT_MSNSET, internal = FALSE, overwrite = TRUE,
                  version = 3, compress = "bzip2")
