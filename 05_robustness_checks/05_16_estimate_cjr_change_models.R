#!/usr/bin/env Rscript

# Estimate how within-topic annual changes in EffJ relate to changes in CJR.

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(fixest)
})

setFixest_nthreads(8)

input_path <-
  "results/direct_outcome_gap/temporal_coordination_topic_year.parquet"
panel_output_path <-
  "results/direct_outcome_gap/cjr_first_difference_panel.parquet"
transition_output_path <-
  "results/direct_outcome_gap/cjr_first_difference_transitions.parquet"
result_output_path <-
  "results/direct_outcome_gap/cjr_first_difference_results.csv"
descriptive_output_path <-
  "results/direct_outcome_gap/cjr_first_difference_descriptives.csv"
horizon_result_output_path <-
  "results/direct_outcome_gap/cjr_change_horizon_results.csv"
horizon_descriptive_output_path <-
  "results/direct_outcome_gap/cjr_change_horizon_descriptives.csv"

data <- as.data.table(read_parquet(input_path))
data[, topic_id := as.character(topic_id)]

context_columns <- c(
  "universe", "analytic_field", "publication_year", "topic_id",
  "log_eff_j", "log_cell_n", "top1_journal_share", "oa_share",
  "mean_log_authors", "mean_log_sjr"
)
topic_year <- unique(data[, ..context_columns])

counts <- dcast(
  data,
  universe + analytic_field + publication_year + topic_id ~ pair_type,
  value.var = c("tie_count", "possible_pairs")
)
topic_year <- merge(
  topic_year,
  counts,
  by = c("universe", "analytic_field", "publication_year", "topic_id"),
  all = FALSE
)
setorder(topic_year, universe, topic_id, publication_year)

lag_columns <- c(
  "publication_year", "log_eff_j", "log_cell_n", "top1_journal_share",
  "oa_share", "mean_log_authors", "mean_log_sjr", "tie_count_within",
  "tie_count_cross", "possible_pairs_within", "possible_pairs_cross"
)
for (column_name in lag_columns) {
  topic_year[
    , paste0("lag_", column_name) := shift(get(column_name)),
    by = .(universe, topic_id)
  ]
}

transitions <- topic_year[
  !is.na(lag_publication_year) &
    publication_year == lag_publication_year + 1
]
transitions[
  , `:=`(
    transition_id = paste(universe, topic_id, publication_year, sep = "||"),
    field_transition_id = paste(
      analytic_field, publication_year, sep = "||"
    ),
    delta_log_eff_j = log_eff_j - lag_log_eff_j,
    delta_log_cell_n = log_cell_n - lag_log_cell_n,
    delta_top1_journal_share =
      top1_journal_share - lag_top1_journal_share,
    delta_oa_share = oa_share - lag_oa_share,
    delta_mean_log_authors = mean_log_authors - lag_mean_log_authors,
    delta_mean_log_sjr = mean_log_sjr - lag_mean_log_sjr
  )
]

make_period_boundary <- function(period_value, cross_value) {
  if (period_value == 0L) {
    tie_column <- if (cross_value == 1L) {
      "lag_tie_count_cross"
    } else {
      "lag_tie_count_within"
    }
    pair_column <- if (cross_value == 1L) {
      "lag_possible_pairs_cross"
    } else {
      "lag_possible_pairs_within"
    }
  } else {
    tie_column <- if (cross_value == 1L) {
      "tie_count_cross"
    } else {
      "tie_count_within"
    }
    pair_column <- if (cross_value == 1L) {
      "possible_pairs_cross"
    } else {
      "possible_pairs_within"
    }
  }

  output <- transitions[, .(
    universe,
    analytic_field,
    publication_year,
    topic_id,
    transition_id,
    field_transition_id,
    delta_log_eff_j,
    delta_log_cell_n,
    delta_top1_journal_share,
    delta_oa_share,
    delta_mean_log_authors,
    delta_mean_log_sjr,
    tie_count = get(tie_column),
    possible_pairs = get(pair_column)
  )]
  output[, `:=`(
    period = period_value,
    is_cross_journal = cross_value,
    pair_type = ifelse(cross_value == 1L, "cross", "within")
  )]
  output
}

panel <- rbindlist(list(
  make_period_boundary(0L, 0L),
  make_period_boundary(0L, 1L),
  make_period_boundary(1L, 0L),
  make_period_boundary(1L, 1L)
))
panel[, period_name := ifelse(period == 1L, "current", "previous")]
panel[, `:=`(
  boundary_period = paste(pair_type, period_name, sep = "||"),
  did_log_eff_j = period * is_cross_journal * delta_log_eff_j,
  did_log_cell_n = period * is_cross_journal * delta_log_cell_n,
  did_top1_journal_share =
    period * is_cross_journal * delta_top1_journal_share,
  did_oa_share = period * is_cross_journal * delta_oa_share,
  did_mean_log_authors =
    period * is_cross_journal * delta_mean_log_authors,
  did_mean_log_sjr = period * is_cross_journal * delta_mean_log_sjr,
  log_possible_pairs = log(possible_pairs)
)]

write_parquet(panel, panel_output_path, compression = "zstd")
write_parquet(transitions, transition_output_path, compression = "zstd")

fields <- sort(unique(transitions$analytic_field))

select_sample <- function(input_data, universe_name, field_name) {
  if (startsWith(field_name, "exclude_")) {
    excluded_field <- sub("^exclude_", "", field_name)
    input_data[
      universe == universe_name & analytic_field != excluded_field
    ]
  } else {
    input_data[
      universe == universe_name &
        (field_name == "pooled" | analytic_field == field_name)
    ]
  }
}

extract_effect <- function(
  model,
  coefficient_name,
  universe_name,
  field_name,
  specification,
  delta_sd,
  transition_count,
  topic_count
) {
  coefficient <- coef(model)[[coefficient_name]]
  standard_error <- se(model)[[coefficient_name]]
  data.table(
    universe = universe_name,
    analytic_field = field_name,
    specification = specification,
    coefficient = coefficient,
    standard_error = standard_error,
    percent_cjr_change_for_10pct_effj_increase =
      100 * (exp(coefficient * log(1.10)) - 1),
    percent_cjr_change_for_one_sd_annual_effj_change =
      100 * (exp(coefficient * delta_sd) - 1),
    percent_cjr_change_for_effj_doubling =
      100 * (exp(coefficient * log(2)) - 1),
    confidence_low_for_effj_doubling =
      100 * (exp((coefficient - 1.96 * standard_error) * log(2)) - 1),
    confidence_high_for_effj_doubling =
      100 * (exp((coefficient + 1.96 * standard_error) * log(2)) - 1),
    p_value = pvalue(model)[[coefficient_name]],
    observations = nobs(model),
    transitions = transition_count,
    topics = topic_count,
    sd_delta_log_eff_j = delta_sd
  )
}

fit_ppml <- function(input_data, universe_name, field_name, specification) {
  subset_data <- select_sample(input_data, universe_name, field_name)
  if (specification == "context_adjusted") {
    subset_data <- subset_data[
      complete.cases(
        delta_log_eff_j,
        delta_log_cell_n,
        delta_top1_journal_share,
        delta_oa_share,
        delta_mean_log_authors,
        delta_mean_log_sjr
      )
    ]
    model_formula <- tie_count ~
      did_log_eff_j + did_log_cell_n + did_top1_journal_share +
      did_oa_share + did_mean_log_authors + did_mean_log_sjr |
      transition_id^pair_type + transition_id^period_name +
      field_transition_id^boundary_period
  } else {
    subset_data <- subset_data[!is.na(delta_log_eff_j)]
    model_formula <- tie_count ~ did_log_eff_j |
      transition_id^pair_type + transition_id^period_name +
      field_transition_id^boundary_period
  }
  model <- fepois(
    model_formula,
    offset = ~log_possible_pairs,
    data = subset_data,
    vcov = ~topic_id,
    fixef.rm = "perfect_fit",
    notes = FALSE
  )
  transition_data <- unique(
    subset_data[, .(transition_id, topic_id, delta_log_eff_j)]
  )
  extract_effect(
    model,
    "did_log_eff_j",
    universe_name,
    field_name,
    paste0("first_difference_ppml_", specification),
    sd(transition_data$delta_log_eff_j),
    nrow(transition_data),
    uniqueN(transition_data$topic_id)
  )
}

fit_log_cjr <- function(
  input_data,
  universe_name,
  field_name,
  weighted
) {
  subset_data <- select_sample(input_data, universe_name, field_name)
  subset_data <- subset_data[
    tie_count_cross > 0 & tie_count_within > 0 &
      lag_tie_count_cross > 0 & lag_tie_count_within > 0 &
      complete.cases(
        delta_log_eff_j,
        delta_log_cell_n,
        delta_top1_journal_share,
        delta_oa_share,
        delta_mean_log_authors,
        delta_mean_log_sjr
      )
  ]
  subset_data[, `:=`(
    delta_log_cjr =
      log(tie_count_cross / possible_pairs_cross) -
      log(tie_count_within / possible_pairs_within) -
      log(lag_tie_count_cross / lag_possible_pairs_cross) +
      log(lag_tie_count_within / lag_possible_pairs_within),
    precision_weight = 1 / (
      1 / tie_count_cross + 1 / tie_count_within +
      1 / lag_tie_count_cross + 1 / lag_tie_count_within
    )
  )]
  model_formula <- delta_log_cjr ~
    delta_log_eff_j + delta_log_cell_n + delta_top1_journal_share +
    delta_oa_share + delta_mean_log_authors + delta_mean_log_sjr |
    field_transition_id
  model <- if (weighted) {
    feols(
      model_formula,
      data = subset_data,
      weights = ~precision_weight,
      vcov = ~topic_id,
      notes = FALSE
    )
  } else {
    feols(
      model_formula,
      data = subset_data,
      vcov = ~topic_id,
      notes = FALSE
    )
  }
  extract_effect(
    model,
    "delta_log_eff_j",
    universe_name,
    field_name,
    ifelse(
      weighted,
      "first_difference_log_cjr_precision_weighted",
      "first_difference_log_cjr_unweighted"
    ),
    sd(subset_data$delta_log_eff_j),
    nrow(subset_data),
    uniqueN(subset_data$topic_id)
  )
}

results <- list()
result_index <- 1L
for (universe_name in c("full", "scimago")) {
  for (field_name in c("pooled", fields)) {
    for (specification in c("baseline", "context_adjusted")) {
      results[[result_index]] <- fit_ppml(
        panel, universe_name, field_name, specification
      )
      result_index <- result_index + 1L
    }
  }
  for (excluded_field in fields) {
    results[[result_index]] <- fit_ppml(
      panel,
      universe_name,
      paste0("exclude_", excluded_field),
      "context_adjusted"
    )
    result_index <- result_index + 1L
  }
  for (weighted in c(FALSE, TRUE)) {
    results[[result_index]] <- fit_log_cjr(
      transitions, universe_name, "pooled", weighted
    )
    result_index <- result_index + 1L
  }
}

result_table <- rbindlist(results, fill = TRUE)
fwrite(result_table, result_output_path)
print(result_table)

descriptives <- transitions[
  , .(
    transitions = .N,
    topics = uniqueN(topic_id),
    mean_delta_log_eff_j = mean(delta_log_eff_j),
    sd_delta_log_eff_j = sd(delta_log_eff_j),
    q025_delta_log_eff_j = quantile(delta_log_eff_j, 0.025),
    median_delta_log_eff_j = median(delta_log_eff_j),
    q975_delta_log_eff_j = quantile(delta_log_eff_j, 0.975),
    correlation_effj_level_across_years = cor(log_eff_j, lag_log_eff_j)
  ),
  by = universe
]
fwrite(descriptives, descriptive_output_path)
print(descriptives)

# Longer changes reduce the influence of year-to-year measurement noise in two
# highly persistent series. Overlapping intervals are retained, with inference
# clustered by topic to allow arbitrary serial dependence within topic.
build_horizon_data <- function(input_topic_year, horizon) {
  base_columns <- c(
    "universe", "analytic_field", "publication_year", "topic_id",
    "log_eff_j", "log_cell_n", "top1_journal_share", "oa_share",
    "mean_log_authors", "mean_log_sjr", "tie_count_within",
    "tie_count_cross", "possible_pairs_within", "possible_pairs_cross"
  )
  horizon_data <- copy(input_topic_year[, ..base_columns])
  setorder(horizon_data, universe, topic_id, publication_year)
  shifted_columns <- setdiff(
    base_columns,
    c("universe", "analytic_field", "topic_id")
  )
  for (column_name in shifted_columns) {
    horizon_data[
      , paste0("previous_", column_name) :=
        shift(get(column_name), n = horizon),
      by = .(universe, topic_id)
    ]
  }
  horizon_transitions <- horizon_data[
    !is.na(previous_publication_year) &
      publication_year == previous_publication_year + horizon
  ]
  horizon_transitions[, `:=`(
    horizon_years = horizon,
    transition_id = paste(
      universe, topic_id, publication_year, horizon, sep = "||"
    ),
    field_transition_id = paste(
      analytic_field, publication_year, sep = "||"
    ),
    delta_log_eff_j = log_eff_j - previous_log_eff_j,
    delta_log_cell_n = log_cell_n - previous_log_cell_n,
    delta_top1_journal_share =
      top1_journal_share - previous_top1_journal_share,
    delta_oa_share = oa_share - previous_oa_share,
    delta_mean_log_authors =
      mean_log_authors - previous_mean_log_authors,
    delta_mean_log_sjr = mean_log_sjr - previous_mean_log_sjr
  )]

  make_horizon_cell <- function(period_value, cross_value) {
    prefix <- ifelse(period_value == 0L, "previous_", "")
    boundary <- ifelse(cross_value == 1L, "cross", "within")
    output <- horizon_transitions[, .(
      universe,
      analytic_field,
      publication_year,
      topic_id,
      horizon_years,
      transition_id,
      field_transition_id,
      delta_log_eff_j,
      delta_log_cell_n,
      delta_top1_journal_share,
      delta_oa_share,
      delta_mean_log_authors,
      delta_mean_log_sjr,
      tie_count = get(paste0(prefix, "tie_count_", boundary)),
      possible_pairs = get(paste0(prefix, "possible_pairs_", boundary))
    )]
    output[, `:=`(
      period = period_value,
      is_cross_journal = cross_value,
      pair_type = boundary
    )]
    output
  }

  horizon_panel <- rbindlist(list(
    make_horizon_cell(0L, 0L),
    make_horizon_cell(0L, 1L),
    make_horizon_cell(1L, 0L),
    make_horizon_cell(1L, 1L)
  ))
  horizon_panel[
    , period_name := ifelse(period == 1L, "current", "previous")
  ]
  horizon_panel[, `:=`(
    boundary_period = paste(pair_type, period_name, sep = "||"),
    did_log_eff_j = period * is_cross_journal * delta_log_eff_j,
    did_log_cell_n = period * is_cross_journal * delta_log_cell_n,
    did_top1_journal_share =
      period * is_cross_journal * delta_top1_journal_share,
    did_oa_share = period * is_cross_journal * delta_oa_share,
    did_mean_log_authors =
      period * is_cross_journal * delta_mean_log_authors,
    did_mean_log_sjr = period * is_cross_journal * delta_mean_log_sjr,
    log_possible_pairs = log(possible_pairs)
  )]
  list(transitions = horizon_transitions, panel = horizon_panel)
}

fit_horizon_ppml <- function(
  horizon_data,
  universe_name,
  specification
) {
  transition_data <- horizon_data$transitions[universe == universe_name]
  subset_data <- horizon_data$panel[universe == universe_name]
  if (specification == "baseline") {
    model_formula <- tie_count ~ did_log_eff_j |
      transition_id^pair_type + transition_id^period +
      field_transition_id^boundary_period
  } else {
    model_formula <- tie_count ~
      did_log_eff_j + did_log_cell_n + did_top1_journal_share +
      did_oa_share + did_mean_log_authors + did_mean_log_sjr |
      transition_id^pair_type + transition_id^period +
      field_transition_id^boundary_period
  }
  model <- fepois(
    model_formula,
    data = subset_data,
    offset = ~log_possible_pairs,
    vcov = ~topic_id,
    notes = FALSE
  )
  effect <- extract_effect(
    model,
    "did_log_eff_j",
    universe_name,
    "pooled",
    paste0("change_ppml_", specification),
    sd(transition_data$delta_log_eff_j),
    nrow(transition_data),
    uniqueN(transition_data$topic_id)
  )
  effect[, horizon_years := unique(transition_data$horizon_years)]
  setcolorder(effect, c(
    "universe", "analytic_field", "specification", "horizon_years"
  ))
  effect
}

horizon_results <- list()
horizon_descriptives <- list()
horizon_index <- 1L
for (horizon in 1:3) {
  horizon_data <- build_horizon_data(topic_year, horizon)
  for (universe_name in c("full", "scimago")) {
    transition_data <-
      horizon_data$transitions[universe == universe_name]
    horizon_descriptives[[horizon_index]] <- transition_data[, .(
      universe = universe_name,
      horizon_years = horizon,
      transitions = .N,
      topics = uniqueN(topic_id),
      mean_delta_log_eff_j = mean(delta_log_eff_j),
      sd_delta_log_eff_j = sd(delta_log_eff_j),
      correlation_effj_endpoints = cor(log_eff_j, previous_log_eff_j)
    )]
    for (specification in c("baseline", "context_adjusted")) {
      horizon_results[[length(horizon_results) + 1L]] <- fit_horizon_ppml(
        horizon_data,
        universe_name,
        specification
      )
    }
    horizon_index <- horizon_index + 1L
  }
}

horizon_result_table <- rbindlist(horizon_results, fill = TRUE)
horizon_descriptive_table <- rbindlist(horizon_descriptives, fill = TRUE)
fwrite(horizon_result_table, horizon_result_output_path)
fwrite(horizon_descriptive_table, horizon_descriptive_output_path)
print(horizon_result_table)
print(horizon_descriptive_table)
