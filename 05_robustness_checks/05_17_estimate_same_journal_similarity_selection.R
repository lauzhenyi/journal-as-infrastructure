#!/usr/bin/env Rscript

# Test whether same-journal pairs become more intellectually similar as EffJ rises.

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(fixest)
  library(splines)
})

setFixest_nthreads(8)

input_path <-
  "results/direct_outcome_gap/pair_level_boundary_pairs.parquet"
output_directory <- "results/direct_outcome_gap"
model_output_path <- file.path(
  output_directory,
  "same_journal_similarity_selection_results.csv"
)
descriptive_output_path <- file.path(
  output_directory,
  "same_journal_similarity_selection_descriptives.csv"
)

data <- as.data.table(read_parquet(input_path))
data[, later_publication_year := as.character(as.integer(format(later_date, "%Y")))]
data[, focal_publication_year := as.character(focal_publication_year)]
data[, focal_work_id := as.character(focal_work_id)]
data[, focal_topic_id := as.character(focal_topic_id)]
data[, focal_text_cluster_id := as.character(focal_text_cluster_id)]
data[, log_date_distance := log1p(publication_date_distance_days)]

outcomes <- c("cosine_similarity", "bibliographic_coupling_cosine")
universes <- c("full", "scimago")
exposures <- c("openalex_log_eff_j", "text_log_eff_j")
weighting_schemes <- c("pair_weighted", "family_weighted")


cluster_variable <- function(exposure_name) {
  if (exposure_name == "text_log_eff_j") {
    "focal_text_cluster_id"
  } else {
    "focal_topic_id"
  }
}


extract_term <- function(model, term_candidates) {
  term_name <- intersect(term_candidates, names(coef(model)))
  if (length(term_name) != 1L) {
    stop(paste(
      "Expected exactly one matching coefficient; found",
      paste(term_name, collapse = ", ")
    ))
  }
  list(
    term = term_name,
    coefficient = unname(coef(model)[[term_name]]),
    standard_error = unname(se(model)[[term_name]]),
    p_value = unname(pvalue(model)[[term_name]])
  )
}


prepare_weights <- function(input_data, weighting, same_journal_only = FALSE) {
  subset_data <- copy(input_data)
  if (same_journal_only) {
    subset_data <- subset_data[same_journal == 1L]
  }
  if (weighting == "family_weighted") {
    subset_data[, analysis_weight := 1 / .N, by = focal_work_id]
  } else {
    subset_data[, analysis_weight := 1.0]
  }
  subset_data
}


fit_within_family_gap <- function(
  input_data,
  universe_name,
  exposure_name,
  outcome_name,
  weighting
) {
  subset_data <- prepare_weights(
    input_data[universe == universe_name],
    weighting,
    same_journal_only = FALSE
  )
  formula <- as.formula(paste0(
    outcome_name,
    " ~ same_journal + same_journal:", exposure_name,
    " + ns(log_date_distance, df = 3)",
    " | focal_work_id + later_publication_year"
  ))
  model <- feols(
    formula,
    data = subset_data,
    weights = ~analysis_weight,
    vcov = as.formula(paste0("~", cluster_variable(exposure_name))),
    fixef.rm = "none",
    notes = FALSE
  )
  extracted <- extract_term(
    model,
    c(
      paste0("same_journal:", exposure_name),
      paste0(exposure_name, ":same_journal")
    )
  )
  outcome_sd <- sd(subset_data[[outcome_name]], na.rm = TRUE)
  data.table(
    test = "within_family_same_vs_cross_similarity_gap",
    universe = universe_name,
    exposure = exposure_name,
    outcome = outcome_name,
    weighting = weighting,
    fixed_effects = "focal_work_id + later_publication_year",
    coefficient_per_log_effj = extracted$coefficient,
    standard_error = extracted$standard_error,
    change_for_effj_doubling = extracted$coefficient * log(2),
    confidence_low_for_effj_doubling =
      (extracted$coefficient - 1.96 * extracted$standard_error) * log(2),
    confidence_high_for_effj_doubling =
      (extracted$coefficient + 1.96 * extracted$standard_error) * log(2),
    change_in_outcome_sd_for_effj_doubling =
      extracted$coefficient * log(2) / outcome_sd,
    p_value = extracted$p_value,
    observations = nobs(model),
    focal_families = uniqueN(subset_data$focal_work_id),
    clusters = uniqueN(subset_data[[cluster_variable(exposure_name)]])
  )
}


fit_same_journal_slope <- function(
  input_data,
  universe_name,
  exposure_name,
  outcome_name,
  weighting
) {
  subset_data <- prepare_weights(
    input_data[universe == universe_name],
    weighting,
    same_journal_only = TRUE
  )
  formula <- as.formula(paste0(
    outcome_name,
    " ~ ", exposure_name,
    " + ns(log_date_distance, df = 3)",
    " | ", cluster_variable(exposure_name),
    " + analytic_field^focal_publication_year"
  ))
  model <- feols(
    formula,
    data = subset_data,
    weights = ~analysis_weight,
    vcov = as.formula(paste0("~", cluster_variable(exposure_name))),
    fixef.rm = "none",
    notes = FALSE
  )
  extracted <- extract_term(model, exposure_name)
  outcome_sd <- sd(subset_data[[outcome_name]], na.rm = TRUE)
  data.table(
    test = "same_journal_pair_similarity_slope",
    universe = universe_name,
    exposure = exposure_name,
    outcome = outcome_name,
    weighting = weighting,
    fixed_effects = paste0(
      cluster_variable(exposure_name),
      " + analytic_field x focal_publication_year"
    ),
    coefficient_per_log_effj = extracted$coefficient,
    standard_error = extracted$standard_error,
    change_for_effj_doubling = extracted$coefficient * log(2),
    confidence_low_for_effj_doubling =
      (extracted$coefficient - 1.96 * extracted$standard_error) * log(2),
    confidence_high_for_effj_doubling =
      (extracted$coefficient + 1.96 * extracted$standard_error) * log(2),
    change_in_outcome_sd_for_effj_doubling =
      extracted$coefficient * log(2) / outcome_sd,
    p_value = extracted$p_value,
    observations = nobs(model),
    focal_families = uniqueN(subset_data$focal_work_id),
    clusters = uniqueN(subset_data[[cluster_variable(exposure_name)]])
  )
}


results <- list()
result_index <- 1L
for (universe_name in universes) {
  for (exposure_name in exposures) {
    for (outcome_name in outcomes) {
      for (weighting in weighting_schemes) {
        results[[result_index]] <- fit_within_family_gap(
          data,
          universe_name,
          exposure_name,
          outcome_name,
          weighting
        )
        result_index <- result_index + 1L
        results[[result_index]] <- fit_same_journal_slope(
          data,
          universe_name,
          exposure_name,
          outcome_name,
          weighting
        )
        result_index <- result_index + 1L
      }
    }
  }
}

result_table <- rbindlist(results, fill = TRUE)
setorder(result_table, test, universe, exposure, outcome, weighting)
fwrite(result_table, model_output_path)
print(result_table)

descriptive_tables <- list()
descriptive_index <- 1L
for (universe_name in universes) {
  for (exposure_name in exposures) {
    subset_data <- copy(data[universe == universe_name])
    subset_data[, exposure_label := exposure_name]
    subset_data[, effj_quartile := cut(
      get(exposure_name),
      breaks = unique(quantile(
        get(exposure_name),
        probs = seq(0, 1, 0.25),
        na.rm = TRUE
      )),
      include.lowest = TRUE,
      labels = FALSE
    )]
    descriptive_tables[[descriptive_index]] <- subset_data[
      !is.na(effj_quartile),
      .(
        pairs = .N,
        focal_families = uniqueN(focal_work_id),
        mean_effj = mean(exp(get(exposure_name))),
        mean_cosine_similarity = mean(cosine_similarity),
        mean_bibliographic_coupling = mean(bibliographic_coupling_cosine)
      ),
      by = .(
        universe,
        exposure = exposure_label,
        effj_quartile,
        boundary = fifelse(same_journal == 1L, "same_journal", "cross_journal")
      )
    ]
    descriptive_index <- descriptive_index + 1L
  }
}

descriptive_table <- rbindlist(descriptive_tables, fill = TRUE)
setorder(descriptive_table, universe, exposure, effj_quartile, boundary)
fwrite(descriptive_table, descriptive_output_path)
print(descriptive_table)
