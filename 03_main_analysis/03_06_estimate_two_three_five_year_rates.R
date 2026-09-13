#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(fixest)
})

setFixest_nthreads(8)

input_path <- "/private/tmp/researcher_portfolio_integration_windows_six.parquet"
output_path <-
  "results/six_field_analysis/researcher_portfolio_windows_fe_results.csv"

dt <- as.data.table(read_parquet(input_path))
dt[, author_id := as.character(author_id)]
dt[, institution_id := as.character(institution_id)]
dt[, field_year_id := as.character(field_year_id)]
dt[, log_focal_papers := log(focal_papers)]
dt[, log_family_citers := log(summed_family_citers)]
dt[, family_size_bin := fifelse(
  summed_family_citers <= 20, as.character(summed_family_citers),
  fifelse(summed_family_citers <= 30, "21-30",
    fifelse(summed_family_citers <= 50, "31-50",
      fifelse(summed_family_citers <= 100, "51-100",
        fifelse(summed_family_citers <= 200, "101-200", "201+"))))
)]

outcomes <- c(
  "venue_localization_gap_pp",
  "portfolio_cross_journal_tie_density_pp",
  "portfolio_isolated_citer_share",
  "portfolio_within_journal_tie_density_pp"
)

fit_one <- function(data, universe_name, horizon_value, field_name, outcome) {
  subset_data <- data[
    universe == universe_name & horizon == horizon_value &
      (field_name == "pooled" | analytic_field == field_name) &
      !is.na(get(outcome))
  ]
  formula_text <- paste0(
    outcome,
    " ~ mean_log_eff_j + mean_log_cell_n + log_focal_papers + ",
    "log_family_citers + mean_log_authors + oa_share | ",
    "author_id + institution_id + field_year_id + family_size_bin"
  )
  model <- feols(
    as.formula(formula_text),
    data = subset_data,
    vcov = ~author_id,
    fixef.rm = "singleton",
    notes = FALSE
  )
  coefficient <- coef(model)[["mean_log_eff_j"]]
  standard_error <- se(model)[["mean_log_eff_j"]]
  data.table(
    universe = universe_name,
    horizon = horizon_value,
    analytic_field = field_name,
    outcome = outcome,
    estimate_log_unit = coefficient,
    standard_error_log_unit = standard_error,
    estimate_doubling = coefficient * log(2),
    standard_error_doubling = standard_error * log(2),
    p_value = pvalue(model)[["mean_log_eff_j"]],
    observations = nobs(model),
    r2_within = fitstat(model, "wr2")[[1]]
  )
}

universes <- c("full", "scimago")
horizons <- c(2L, 3L, 5L)
fields <- c("pooled", sort(unique(dt$analytic_field)))
results <- list()
index <- 1L

for (universe_name in universes) {
  for (horizon_value in horizons) {
    for (outcome in outcomes) {
      for (field_name in fields) {
        message(sprintf(
          "Fitting %s | %sy | %s | %s",
          universe_name, horizon_value, field_name, outcome
        ))
        results[[index]] <- tryCatch(
          fit_one(dt, universe_name, horizon_value, field_name, outcome),
          error = function(error) {
            message(sprintf("FAILED: %s", conditionMessage(error)))
            data.table(
              universe = universe_name,
              horizon = horizon_value,
              analytic_field = field_name,
              outcome = outcome,
              estimate_log_unit = NA_real_,
              standard_error_log_unit = NA_real_,
              estimate_doubling = NA_real_,
              standard_error_doubling = NA_real_,
              p_value = NA_real_,
              observations = NA_integer_,
              r2_within = NA_real_
            )
          }
        )
        index <- index + 1L
      }
    }
  }
}

result_dt <- rbindlist(results, fill = TRUE)
fwrite(result_dt, output_path)
print(result_dt[analytic_field == "pooled"])
