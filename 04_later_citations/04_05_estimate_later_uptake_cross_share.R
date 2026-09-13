#!/usr/bin/env Rscript

# Estimate later uptake from early cross-versus-within citation odds.

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(fixest)
})

setFixest_nthreads(8)

arguments <- commandArgs(trailingOnly = TRUE)
project_root <- if (length(arguments) >= 1L) arguments[[1]] else "."
output_path <- if (length(arguments) >= 2L) {
  arguments[[2]]
} else {
  file.path(
    project_root,
    "results",
    "cumulative_handoff",
    "later_uptake_cross_share_results.csv"
  )
}

input_path <- file.path(
  project_root,
  "results",
  "cumulative_handoff",
  "cumulative_handoff_family_panel.parquet"
)

data <- as.data.table(read_parquet(input_path))
data[, `:=`(
  topic_year_id = as.character(topic_year_id),
  corresponding_author_id = as.character(corresponding_author_id),
  topic_id = as.character(topic_id),
  early_member_factor = as.factor(early_member_count),
  log_late_members = log(late_member_count),
  log_eligible_late_citers = log(eligible_late_citers),
  early_total_ties = early_cross_ties + early_within_ties,
  log_early_total_ties = log1p(early_cross_ties + early_within_ties),
  any_early_tie = as.integer(early_cross_ties + early_within_ties > 0),
  log_early_cross_within_odds = log(
    (early_cross_ties + 0.5) / (early_within_ties + 0.5)
  ),
  log_early_opportunity_odds = log(
    cross_possible_pairs / within_possible_pairs
  )
)]

base_formula <- late_citers_with_handoff ~
  log_early_cross_within_odds + any_early_tie + log_early_total_ties +
  log_early_opportunities + log_late_members +
  log_early_member_prior_citations +
  log_max_early_member_prior_citations + log_authors + oa_value |
  topic_year_id + early_member_factor + corresponding_author_id

opportunity_formula <- late_citers_with_handoff ~
  log_early_cross_within_odds + any_early_tie + log_early_total_ties +
  log_early_opportunity_odds + log_early_opportunities + log_late_members +
  log_early_member_prior_citations +
  log_max_early_member_prior_citations + log_authors + oa_value |
  topic_year_id + early_member_factor + corresponding_author_id

fit_model <- function(
  input_data,
  formula,
  universe_label,
  cohort,
  field_label,
  specification
) {
  model <- fepois(
    formula,
    data = input_data,
    offset = ~log_eligible_late_citers,
    vcov = ~corresponding_author_id + topic_id,
    fixef.rm = "singleton",
    notes = FALSE
  )
  term <- "log_early_cross_within_odds"
  coefficient <- coef(model)[[term]]
  standard_error <- se(model)[[term]]
  effect <- 100 * (exp(coefficient * log(2)) - 1)
  confidence_low <- 100 * (
    exp((coefficient - 1.96 * standard_error) * log(2)) - 1
  )
  confidence_high <- 100 * (
    exp((coefficient + 1.96 * standard_error) * log(2)) - 1
  )
  baseline_rate <- 100 * sum(input_data$late_citers_with_handoff) /
    sum(input_data$eligible_late_citers)

  data.table(
    universe = universe_label,
    cohort = cohort,
    analytic_field = field_label,
    specification = specification,
    estimand = paste(
      "Percent change in later-uptake rate for a doubling of early",
      "cross-versus-within citation odds, conditional on total early ties"
    ),
    coefficient_per_log_odds = coefficient,
    standard_error = standard_error,
    later_uptake_change_percent_for_odds_doubling = effect,
    confidence_low = confidence_low,
    confidence_high = confidence_high,
    baseline_later_uptake_percent = baseline_rate,
    implied_absolute_percentage_point_change = baseline_rate * effect / 100,
    p_value = pvalue(model)[[term]],
    observations = nobs(model)
  )
}

full_data <- data[universe == "full"]
scimago_data <- data[universe == "scimago"]
field_values <- sort(unique(full_data$analytic_field))

results <- rbindlist(c(
  list(
  fit_model(
    full_data,
    base_formula,
    "full",
    "2015-2021",
    "pooled",
    "Total early ties"
  ),
  fit_model(
    full_data,
    opportunity_formula,
    "full",
    "2015-2021",
    "pooled",
    "Total early ties and cross-versus-within opportunities"
  ),
  fit_model(
    full_data[publication_year <= 2020],
    base_formula,
    "full",
    "Complete 2015-2020 cohorts",
    "pooled",
    "Total early ties"
  ),
  fit_model(
    full_data[publication_year <= 2020],
    opportunity_formula,
    "full",
    "Complete 2015-2020 cohorts",
    "pooled",
    "Total early ties and cross-versus-within opportunities"
  ),
  fit_model(
    scimago_data,
    opportunity_formula,
    "scimago",
    "2015-2021",
    "pooled",
    "Total early ties and cross-versus-within opportunities"
  )
  ),
  lapply(field_values, function(field_value) {
    fit_model(
      full_data[analytic_field == field_value],
      opportunity_formula,
      "full",
      "2015-2021",
      field_value,
      "Total early ties and cross-versus-within opportunities"
    )
  })
))

dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
fwrite(results, output_path)
print(results)
