#!/usr/bin/env Rscript

# Cluster-bootstrap the pooled indirect EffJ -> early CJR -> later uptake path.

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(fixest)
})

setFixest_nthreads(8)
set.seed(20260831)

arguments <- commandArgs(trailingOnly = TRUE)
bootstrap_repetitions <- if (length(arguments) >= 1L) {
  as.integer(arguments[[1]])
} else {
  300L
}

outcome_path <-
  "results/cumulative_handoff/cumulative_handoff_subfield_panel.parquet"
mediator_path <-
  "results/direct_outcome_gap/temporal_coordination_topic_year.parquet"
draw_output_path <-
  "results/cumulative_handoff/joint_effj_cjr_handoff_bootstrap_draws.csv"
summary_output_path <-
  "results/cumulative_handoff/joint_effj_cjr_handoff_bootstrap_summary.csv"

outcome_panel <- as.data.table(read_parquet(outcome_path))
outcome_panel[, topic_id := as.character(topic_id)]
outcome_panel[, topic_year_id := as.character(topic_year_id)]
outcome_panel[, topic_pair_id := as.character(topic_pair_id)]
outcome_panel[, field_year_pair_id := as.character(field_year_pair_id)]

mediator_panel <- as.data.table(read_parquet(mediator_path))
mediator_panel[, panel_id := as.character(panel_id)]
mediator_panel[, topic_id := as.character(topic_id)]
mediator_panel[, field_year_id := as.character(field_year_id)]
mediator_panel[, log_possible_pairs := log(possible_pairs)]


interaction_term <- function(model, exposure, boundary) {
  candidates <- c(
    paste0(boundary, ":", exposure),
    paste0(exposure, ":", boundary)
  )
  term <- intersect(candidates, names(coef(model)))
  if (length(term) != 1L) {
    stop(sprintf("Could not identify interaction for %s", exposure))
  }
  term
}


prepare_universe <- function(universe_name) {
  outcome <- outcome_panel[universe == universe_name]
  keys <- unique(outcome[, .(
    universe,
    analytic_field,
    publication_year,
    topic_id
  )])
  mediator <- mediator_panel[
    keys,
    on = .(universe, analytic_field, publication_year, topic_id),
    nomatch = 0
  ]
  list(outcome = outcome, mediator = mediator)
}


fit_bootstrap_draw <- function(prepared, universe_name, repetition) {
  topics <- unique(prepared$outcome$topic_id)
  sampled_topics <- sample(topics, length(topics), replace = TRUE)
  bootstrap_weights <- data.table(topic_id = sampled_topics)[
    , .(bootstrap_weight = .N), by = topic_id
  ]

  outcome <- bootstrap_weights[
    prepared$outcome,
    on = "topic_id",
    nomatch = 0
  ]
  mediator <- bootstrap_weights[
    prepared$mediator,
    on = "topic_id",
    nomatch = 0
  ]

  mediator_model <- fepois(
    tie_count ~ is_cross_journal:log_eff_j |
      panel_id + topic_id^pair_type + field_year_id^pair_type,
    data = mediator,
    offset = ~log_possible_pairs,
    weights = ~bootstrap_weight,
    vcov = "iid",
    fixef.rm = "singleton",
    notes = FALSE
  )

  total_model <- fepois(
    late_citers_with_handoff ~ is_cross:log_eff_j +
      log_early_options_per_late_citer |
      topic_year_id + topic_pair_id + field_year_pair_id,
    data = outcome,
    offset = ~log_eligible_late_citers,
    weights = ~bootstrap_weight,
    vcov = "iid",
    fixef.rm = "singleton",
    notes = FALSE
  )

  joint_model <- fepois(
    late_citers_with_handoff ~ is_cross:log_eff_j +
      is_cross:early_coordination_gap +
      log_early_options_per_late_citer |
      topic_year_id + topic_pair_id + field_year_pair_id,
    data = outcome,
    offset = ~log_eligible_late_citers,
    weights = ~bootstrap_weight,
    vcov = "iid",
    fixef.rm = "singleton",
    notes = FALSE
  )

  a_term <- interaction_term(
    mediator_model, "log_eff_j", "is_cross_journal"
  )
  total_term <- interaction_term(total_model, "log_eff_j", "is_cross")
  direct_term <- interaction_term(joint_model, "log_eff_j", "is_cross")
  b_term <- interaction_term(
    joint_model, "early_coordination_gap", "is_cross"
  )

  a <- coef(mediator_model)[[a_term]]
  b <- coef(joint_model)[[b_term]]
  total <- coef(total_model)[[total_term]]
  direct <- coef(joint_model)[[direct_term]]

  data.table(
    universe = universe_name,
    repetition = repetition,
    a_effj_to_early_log_cjr = a,
    b_early_log_cjr_to_later_cross_boundary = b,
    total_log_effect_per_log_effj = total,
    direct_log_effect_per_log_effj = direct,
    indirect_log_effect_per_log_effj = a * b,
    implied_total_log_effect_per_log_effj = direct + (a * b)
  )
}


draws <- list()
draw_index <- 1L
for (universe_name in c("full", "scimago")) {
  prepared <- prepare_universe(universe_name)
  for (repetition in seq_len(bootstrap_repetitions)) {
    if (repetition %% 50L == 0L) {
      message(sprintf(
        "Bootstrap | %s | %d/%d",
        universe_name, repetition, bootstrap_repetitions
      ))
    }
    draws[[draw_index]] <- fit_bootstrap_draw(
      prepared, universe_name, repetition
    )
    draw_index <- draw_index + 1L
  }
}

draw_table <- rbindlist(draws)
fwrite(draw_table, draw_output_path)

effect_columns <- c(
  "a_effj_to_early_log_cjr",
  "b_early_log_cjr_to_later_cross_boundary",
  "total_log_effect_per_log_effj",
  "direct_log_effect_per_log_effj",
  "indirect_log_effect_per_log_effj",
  "implied_total_log_effect_per_log_effj"
)

summary_table <- melt(
  draw_table,
  id.vars = c("universe", "repetition"),
  measure.vars = effect_columns,
  variable.name = "effect",
  value.name = "estimate"
)[
  , .(
    bootstrap_repetitions = .N,
    bootstrap_mean = mean(estimate),
    bootstrap_standard_error = sd(estimate),
    ci_low = quantile(estimate, 0.025),
    ci_high = quantile(estimate, 0.975),
    share_at_or_below_zero = mean(estimate <= 0),
    share_at_or_above_zero = mean(estimate >= 0)
  ),
  by = .(universe, effect)
]

fwrite(summary_table, summary_output_path)
print(summary_table)
