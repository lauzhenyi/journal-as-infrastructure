#!/usr/bin/env Rscript

# Estimate the main rate-ratio comparison after removing self-citation edges.

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(fixest)
})

setFixest_nthreads(8)

output_path <-
  "results/direct_outcome_gap/self_citation_sensitivity_results.csv"


fit_panel <- function(
  input_path,
  model_level,
  cluster_name,
  year_name
) {
  data <- as.data.table(read_parquet(input_path))
  data[, panel_id := as.character(panel_id)]
  data[, topic_id := as.character(topic_id)]
  data[, field_year_id := as.character(field_year_id)]
  data[, log_possible_pairs := log(possible_pairs)]

  fit_one <- function(
    universe_name,
    sensitivity_name,
    field_name = "pooled"
  ) {
    subset_data <- data[
      universe == universe_name & sensitivity == sensitivity_name &
        (field_name == "pooled" | analytic_field == field_name)
    ]
    formula <- tie_count ~ is_cross_journal +
      is_cross_journal:log_eff_j |
      panel_id + topic_id^pair_type + field_year_id^pair_type
    model <- fepois(
      formula,
      offset = ~log_possible_pairs,
      data = subset_data,
      vcov = as.formula(paste0("~", cluster_name)),
      fixef.rm = "singleton",
      notes = FALSE
    )
    coefficient_name <- names(coef(model))[grepl(
      "is_cross_journal:log_eff_j|log_eff_j:is_cross_journal",
      names(coef(model))
    )]
    coefficient <- coef(model)[[coefficient_name]]
    standard_error <- se(model)[[coefficient_name]]
    log_rate_doubling <- coefficient * log(2)
    standard_error_doubling <- standard_error * log(2)
    data.table(
      model_level = model_level,
      universe = universe_name,
      sensitivity = sensitivity_name,
      analytic_field = field_name,
      coefficient = coefficient,
      standard_error = standard_error,
      percent_change_for_effj_doubling =
        100 * (exp(log_rate_doubling) - 1),
      ci_low_percent =
        100 * (exp(log_rate_doubling - 1.96 * standard_error_doubling) - 1),
      ci_high_percent =
        100 * (exp(log_rate_doubling + 1.96 * standard_error_doubling) - 1),
      p_value = pvalue(model)[[coefficient_name]],
      observations = nobs(model),
      year_variable = year_name
    )
  }

  results <- list()
  result_index <- 1L
  fields <- sort(unique(data$analytic_field))
  for (universe_name in c("full", "scimago")) {
    for (sensitivity_name in sort(unique(data$sensitivity))) {
      for (field_name in c("pooled", fields)) {
        results[[result_index]] <- fit_one(
          universe_name,
          sensitivity_name,
          field_name
        )
        result_index <- result_index + 1L
      }
    }
  }
  rbindlist(results)
}


topic_results <- fit_panel(
  "results/direct_outcome_gap/self_citation_topic_year_panel.parquet",
  "topic_year",
  "topic_id",
  "publication_year"
)
researcher_results <- fit_panel(
  "results/direct_outcome_gap/self_citation_researcher_panel.parquet",
  "corresponding_author",
  "author_id",
  "cohort_year"
)

results <- rbindlist(list(topic_results, researcher_results), fill = TRUE)
fwrite(results, output_path)
print(results)
