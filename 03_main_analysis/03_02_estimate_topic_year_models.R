#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(fixest)
})

setFixest_nthreads(8)

input_path <- "results/direct_outcome_gap/temporal_coordination_topic_year.parquet"
output_path <- "results/direct_outcome_gap/temporal_coordination_fe_results.csv"

data <- as.data.table(read_parquet(input_path))
data[, panel_id := as.character(panel_id)]
data[, topic_id := as.character(topic_id)]
data[, field_year_id := as.character(field_year_id)]
data[, log_possible_pairs := log(possible_pairs)]


fit_one <- function(data, universe_name, field_name, specification) {
  if (startsWith(field_name, "exclude_")) {
    excluded_field <- sub("^exclude_", "", field_name)
    subset_data <- data[
      universe == universe_name & analytic_field != excluded_field
    ]
  } else {
    subset_data <- data[
      universe == universe_name &
        (field_name == "pooled" | analytic_field == field_name)
    ]
  }
  if (specification == "current_effj") {
    formula <- tie_count ~ is_cross_journal +
      is_cross_journal:log_eff_j |
      panel_id + topic_id^pair_type + field_year_id^pair_type
    exposure_name <- "log_eff_j"
  } else if (specification == "context_controls") {
    subset_data <- subset_data[!is.na(mean_log_sjr)]
    formula <- tie_count ~ is_cross_journal +
      is_cross_journal:log_eff_j +
      is_cross_journal:log_cell_n +
      is_cross_journal:top1_journal_share +
      is_cross_journal:oa_share +
      is_cross_journal:mean_log_authors +
      is_cross_journal:mean_log_sjr |
      panel_id + topic_id^pair_type + field_year_id^pair_type
    exposure_name <- "log_eff_j"
  } else {
    stop("Unknown specification")
  }
  model <- fepois(
    formula,
    offset = ~log_possible_pairs,
    data = subset_data,
    vcov = ~topic_id,
    fixef.rm = "singleton",
    notes = FALSE
  )
  coefficient_name <- names(coef(model))[grepl(
    paste0(
      "is_cross_journal:", exposure_name,
      "|", exposure_name, ":is_cross_journal"
    ),
    names(coef(model))
  )]
  coefficient <- coef(model)[[coefficient_name]]
  standard_error <- se(model)[[coefficient_name]]
  data.table(
    universe = universe_name,
    analytic_field = field_name,
    specification = specification,
    outcome = "cross_vs_within_temporally_eligible_tie_rate",
    percent_change_for_effj_doubling =
      100 * (exp(coefficient * log(2)) - 1),
    standard_error_log_rate_doubling = standard_error * log(2),
    p_value = pvalue(model)[[coefficient_name]],
    observations = nobs(model)
  )
}


results <- list()
result_index <- 1L
fields <- sort(unique(data$analytic_field))
for (universe_name in c("full", "scimago")) {
  for (field_name in c("pooled", fields)) {
    for (specification in c("current_effj", "context_controls")) {
      results[[result_index]] <- fit_one(
        data, universe_name, field_name, specification
      )
      result_index <- result_index + 1L
    }
  }
  for (excluded_field in fields) {
    results[[result_index]] <- fit_one(
      data,
      universe_name,
      paste0("exclude_", excluded_field),
      "current_effj"
    )
    result_index <- result_index + 1L
  }
}

result_table <- rbindlist(results)
fwrite(result_table, output_path)
print(result_table)
