#!/usr/bin/env Rscript

# Estimate pair-level fixed-effect logistic robustness specifications.

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(fixest)
  library(splines)
})

setFixest_nthreads(8)

input_path <-
  "results/direct_outcome_gap/pair_level_boundary_pairs.parquet"
output_path <-
  "results/direct_outcome_gap/pair_level_boundary_logit_results.csv"

data <- as.data.table(read_parquet(input_path))
data[, later_publication_year := as.character(as.integer(format(later_date, "%Y")))]
data[, focal_work_id := as.character(focal_work_id)]
data[, focal_topic_id := as.character(focal_topic_id)]
data[, focal_text_cluster_id := as.character(focal_text_cluster_id)]
data[, log_date_distance := log1p(publication_date_distance_days)]


fit_one <- function(data, universe_name, exposure_name) {
  subset_data <- data[universe == universe_name]
  cluster_name <- if (exposure_name == "text_log_eff_j") {
    "focal_text_cluster_id"
  } else {
    "focal_topic_id"
  }
  model_formula <- as.formula(paste0(
    "tie_count ~ same_journal + same_journal:", exposure_name,
    " + ns(cosine_similarity, df = 4)",
    " + bibliographic_coupling_cosine + shared_topic_jaccard",
    " + author_overlap + institution_overlap + country_overlap",
    " + ns(log_date_distance, df = 3)",
    " | focal_work_id + later_publication_year"
  ))
  model <- feglm(
    model_formula,
    data = subset_data,
    family = "binomial",
    vcov = as.formula(paste0("~", cluster_name)),
    fixef.rm = "perfect_fit",
    notes = FALSE
  )
  candidate_names <- c(
    paste0("same_journal:", exposure_name),
    paste0(exposure_name, ":same_journal")
  )
  coefficient_name <- intersect(candidate_names, names(coef(model)))
  if (length(coefficient_name) != 1L) {
    stop(paste("Could not identify interaction for", exposure_name))
  }
  coefficient <- coef(model)[[coefficient_name]]
  standard_error <- se(model)[[coefficient_name]]
  data.table(
    universe = universe_name,
    exposure = exposure_name,
    coefficient = coefficient,
    standard_error = standard_error,
    odds_ratio_change_percent_for_effj_doubling =
      100 * (exp(coefficient * log(2)) - 1),
    standard_error_log_odds_doubling = standard_error * log(2),
    p_value = pvalue(model)[[coefficient_name]],
    observations = nobs(model)
  )
}


results <- list()
result_index <- 1L
for (universe_name in c("full", "scimago")) {
  for (exposure_name in c("openalex_log_eff_j", "text_log_eff_j")) {
    results[[result_index]] <- fit_one(data, universe_name, exposure_name)
    result_index <- result_index + 1L
  }
}
result_table <- rbindlist(results)
fwrite(result_table, output_path)
print(result_table)
