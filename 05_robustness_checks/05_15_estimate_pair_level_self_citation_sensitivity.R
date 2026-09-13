#!/usr/bin/env Rscript

# Test the pair-level boundary result after excluding any shared author.

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
  "results/direct_outcome_gap/pair_level_self_citation_sensitivity.csv"
descriptive_path <-
  "results/direct_outcome_gap/pair_level_self_citation_descriptives.csv"

data <- as.data.table(read_parquet(input_path))
data[, later_publication_year :=
  as.character(as.integer(format(later_date, "%Y")))]
data[, focal_work_id := as.character(focal_work_id)]
data[, focal_topic_id := as.character(focal_topic_id)]
data[, focal_text_cluster_id := as.character(focal_text_cluster_id)]
data[, log_date_distance := log1p(publication_date_distance_days)]


fit_one <- function(
  universe_name,
  exposure_name,
  sensitivity_name
) {
  subset_data <- data[universe == universe_name]
  include_author_control <- TRUE
  if (sensitivity_name == "exclude_any_author_overlap") {
    subset_data <- subset_data[author_overlap == 0]
    include_author_control <- FALSE
  }
  cluster_name <- if (exposure_name == "text_log_eff_j") {
    "focal_text_cluster_id"
  } else {
    "focal_topic_id"
  }
  author_term <- if (include_author_control) " + author_overlap" else ""
  model_formula <- as.formula(paste0(
    "tie_count ~ same_journal + same_journal:", exposure_name,
    " + ns(cosine_similarity, df = 4)",
    " + bibliographic_coupling_cosine + shared_topic_jaccard",
    author_term,
    " + institution_overlap + country_overlap",
    " + ns(log_date_distance, df = 3)",
    " | focal_work_id + later_publication_year"
  ))
  model <- fepois(
    model_formula,
    data = subset_data,
    vcov = as.formula(paste0("~", cluster_name)),
    fixef.rm = "perfect_fit",
    notes = FALSE
  )
  coefficient_name <- intersect(
    c(
      paste0("same_journal:", exposure_name),
      paste0(exposure_name, ":same_journal")
    ),
    names(coef(model))
  )
  if (length(coefficient_name) != 1L) {
    stop(paste("Could not identify interaction for", exposure_name))
  }
  coefficient <- coef(model)[[coefficient_name]]
  standard_error <- se(model)[[coefficient_name]]
  log_rate_doubling <- coefficient * log(2)
  standard_error_doubling <- standard_error * log(2)
  data.table(
    universe = universe_name,
    exposure = exposure_name,
    sensitivity = sensitivity_name,
    coefficient = coefficient,
    standard_error = standard_error,
    rate_ratio_change_percent_for_effj_doubling =
      100 * (exp(log_rate_doubling) - 1),
    ci_low_percent =
      100 * (exp(log_rate_doubling - 1.96 * standard_error_doubling) - 1),
    ci_high_percent =
      100 * (exp(log_rate_doubling + 1.96 * standard_error_doubling) - 1),
    p_value = pvalue(model)[[coefficient_name]],
    observations = nobs(model)
  )
}


results <- list()
result_index <- 1L
for (universe_name in c("full", "scimago")) {
  for (exposure_name in c("openalex_log_eff_j", "text_log_eff_j")) {
    for (sensitivity_name in c(
      "all_pairs_control_author_overlap",
      "exclude_any_author_overlap"
    )) {
      results[[result_index]] <- fit_one(
        universe_name,
        exposure_name,
        sensitivity_name
      )
      result_index <- result_index + 1L
    }
  }
}
result_table <- rbindlist(results)
fwrite(result_table, output_path)
print(result_table)

descriptives <- data[, .(
  pairs = .N,
  realized_ties = sum(tie_count),
  author_overlap_share = mean(author_overlap),
  realized_tie_author_overlap_share =
    mean(author_overlap[tie_count == 1]),
  within_realized_tie_author_overlap_share =
    mean(author_overlap[tie_count == 1 & same_journal == 1]),
  cross_realized_tie_author_overlap_share =
    mean(author_overlap[tie_count == 1 & same_journal == 0])
), by = universe]
fwrite(descriptives, descriptive_path)
print(descriptives)
