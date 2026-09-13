#!/usr/bin/env Rscript

# Estimate current, lead, and joint EffJ associations on a common sample.

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(fixest)
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
    "temporal_coordination_topic_year.parquet"
  )
}
output_path <- if (length(arguments) >= 3L) {
  arguments[[3]]
} else {
  file.path(
    project_root,
    "results",
    "direct_outcome_gap",
    "effj_lead_placebo_results.csv"
  )
}

data <- as.data.table(read_parquet(input_path))[universe == "full"]
data[, `:=`(
  panel_id = as.character(panel_id),
  topic_id = as.character(topic_id),
  field_year_id = as.character(field_year_id),
  log_possible_pairs = log(possible_pairs)
)]

lead_values <- unique(data[, .(
  analytic_field,
  publication_year,
  topic_id,
  log_eff_j
)])
setorder(lead_values, topic_id, publication_year)
lead_values[, `:=`(
  lead_year = shift(publication_year, type = "lead"),
  lead_log_eff_j = shift(log_eff_j, type = "lead")
), by = topic_id]
lead_values <- lead_values[
  lead_year == publication_year + 1,
  .(analytic_field, publication_year, topic_id, lead_log_eff_j)
]

common_sample <- merge(
  data,
  lead_values,
  by = c("analytic_field", "publication_year", "topic_id"),
  all = FALSE
)

current_formula <- tie_count ~ is_cross_journal:log_eff_j |
  panel_id + topic_id^pair_type + field_year_id^pair_type
lead_formula <- tie_count ~ is_cross_journal:lead_log_eff_j |
  panel_id + topic_id^pair_type + field_year_id^pair_type
joint_formula <- tie_count ~ is_cross_journal:log_eff_j +
  is_cross_journal:lead_log_eff_j |
  panel_id + topic_id^pair_type + field_year_id^pair_type

fit_model <- function(formula, term, label) {
  model <- fepois(
    formula,
    data = common_sample,
    offset = ~log_possible_pairs,
    vcov = ~topic_id,
    fixef.rm = "singleton",
    notes = FALSE
  )
  coefficient <- coef(model)[[term]]
  standard_error <- se(model)[[term]]

  data.table(
    specification = label,
    coefficient = coefficient,
    standard_error = standard_error,
    cjr_change_percent_for_effj_doubling =
      100 * (exp(coefficient * log(2)) - 1),
    confidence_low = 100 * (
      exp((coefficient - 1.96 * standard_error) * log(2)) - 1
    ),
    confidence_high = 100 * (
      exp((coefficient + 1.96 * standard_error) * log(2)) - 1
    ),
    p_value = pvalue(model)[[term]],
    observations = nobs(model)
  )
}

results <- rbindlist(list(
  fit_model(
    current_formula,
    "is_cross_journal:log_eff_j",
    "Current EffJ on common sample"
  ),
  fit_model(
    lead_formula,
    "is_cross_journal:lead_log_eff_j",
    "Year t+1 EffJ lead"
  ),
  fit_model(
    joint_formula,
    "is_cross_journal:log_eff_j",
    "Joint model: current EffJ"
  ),
  fit_model(
    joint_formula,
    "is_cross_journal:lead_log_eff_j",
    "Joint model: year t+1 EffJ"
  )
))

dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
fwrite(results, output_path)
print(results)
