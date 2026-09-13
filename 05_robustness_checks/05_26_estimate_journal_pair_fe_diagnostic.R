#!/usr/bin/env Rscript

# Diagnose identification and sample selection under journal-pair fixed effects.

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(fixest)
  library(splines)
})

setFixest_nthreads(8)

arguments <- commandArgs(trailingOnly = TRUE)
project_root <- if (length(arguments) >= 1L) arguments[[1]] else "."
input_path <- if (length(arguments) >= 2L) {
  arguments[[2]]
} else {
  file.path(
    project_root,
    "results",
    "direct_outcome_gap",
    "pair_level_boundary_pairs.parquet"
  )
}
output_path <- if (length(arguments) >= 3L) {
  arguments[[3]]
} else {
  file.path(
    project_root,
    "results",
    "direct_outcome_gap",
    "journal_pair_fe_diagnostic_results.csv"
  )
}

data <- as.data.table(read_parquet(input_path))[universe == "full"]
data[, row_id := .I]
data[, `:=`(
  focal_work_id = as.character(focal_work_id),
  focal_topic_id = as.character(focal_topic_id),
  later_publication_year = as.character(as.integer(format(later_date, "%Y"))),
  log_date_distance = log1p(publication_date_distance_days),
  journal_pair_unordered = fifelse(
    later_source_id <= earlier_source_id,
    paste(later_source_id, earlier_source_id, sep = "||"),
    paste(earlier_source_id, later_source_id, sep = "||")
  )
)]

controls <- paste(
  "ns(cosine_similarity, df = 4)",
  "+ bibliographic_coupling_cosine + shared_topic_jaccard",
  "+ author_overlap + institution_overlap + country_overlap",
  "+ ns(log_date_distance, df = 3)"
)

baseline_formula <- as.formula(paste0(
  "tie_count ~ same_journal + same_journal:openalex_log_eff_j + ",
  controls,
  " | focal_work_id + later_publication_year"
))
journal_pair_formula <- as.formula(paste0(
  "tie_count ~ same_journal:openalex_log_eff_j + ",
  controls,
  " | focal_work_id + later_publication_year + journal_pair_unordered"
))

baseline_full_model <- fepois(
  baseline_formula,
  data = data,
  vcov = ~focal_topic_id,
  fixef.rm = "perfect_fit",
  notes = FALSE
)
journal_pair_model <- fepois(
  journal_pair_formula,
  data = data,
  vcov = ~focal_topic_id,
  fixef.rm = "perfect_fit",
  notes = FALSE,
  data.save = TRUE
)

common_sample <- data[obs(journal_pair_model)]
baseline_common_model <- fepois(
  baseline_formula,
  data = common_sample,
  vcov = ~focal_topic_id,
  fixef.rm = "perfect_fit",
  notes = FALSE
)

full_observations <- nobs(baseline_full_model)

summarize_model <- function(model, label) {
  term <- intersect(
    c(
      "same_journal:openalex_log_eff_j",
      "openalex_log_eff_j:same_journal"
    ),
    names(coef(model))
  )[[1]]
  coefficient <- coef(model)[[term]]
  standard_error <- se(model)[[term]]

  data.table(
    specification = label,
    coefficient_same_vs_cross = coefficient,
    standard_error = standard_error,
    reciprocal_cjr_change_percent_for_effj_doubling =
      100 * (exp(-coefficient * log(2)) - 1),
    confidence_low = 100 * (
      exp(-(coefficient + 1.96 * standard_error) * log(2)) - 1
    ),
    confidence_high = 100 * (
      exp(-(coefficient - 1.96 * standard_error) * log(2)) - 1
    ),
    p_value = pvalue(model)[[term]],
    observations = nobs(model),
    percent_of_full_sample = 100 * nobs(model) / full_observations
  )
}

results <- rbindlist(list(
  summarize_model(baseline_full_model, "Baseline full sample"),
  summarize_model(journal_pair_model, "Journal-pair fixed effects"),
  summarize_model(
    baseline_common_model,
    "Baseline on journal-pair-FE common sample"
  )
))

dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
fwrite(results, output_path)
print(results)
