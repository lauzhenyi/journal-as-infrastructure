#!/usr/bin/env Rscript

# Render appendix sensitivity figures with terminology matched to the main figures.

Sys.setenv(XDG_CACHE_HOME = "/private/tmp/journal_structure_font_cache")
dir.create(Sys.getenv("XDG_CACHE_HOME"), recursive = TRUE, showWarnings = FALSE)

suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
  library(patchwork)
  library(readr)
  library(stringr)
})

result_dir <- "results/direct_outcome_gap"
figure_dir <- file.path(result_dir, "figures", "appendix")
dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)

font_family <- "Arial"
ink <- "#171717"
blue <- "#0072B2"
orange <- "#D55E00"
green <- "#009E73"
dark_grey <- "#666666"

field_order <- c(
  "Biology", "Chemistry", "Geology", "Materials science", "Medicine", "Physics"
)

clean_field <- function(x) {
  recode(
    x,
    biology = "Biology",
    chemistry = "Chemistry",
    geology = "Geology",
    materials_science = "Materials science",
    medicine = "Medicine",
    physics = "Physics"
  )
}

theme_appendix <- function() {
  theme_classic(base_size = 9.75, base_family = font_family) +
    theme(
      axis.title = element_text(size = 9.75, colour = ink),
      axis.text = element_text(size = 8.85, colour = ink),
      axis.title.y = element_text(margin = margin(r = 5)),
      axis.line = element_line(linewidth = 0.35, colour = ink),
      axis.ticks = element_line(linewidth = 0.35, colour = ink),
      axis.ticks.length = unit(1.4, "mm"),
      strip.background = element_blank(),
      strip.text = element_text(size = 9.25, face = "bold", hjust = 0),
      legend.position = "top",
      legend.title = element_blank(),
      legend.text = element_text(size = 8.85),
      plot.title = element_text(size = 10.4, face = "bold", hjust = 0),
      plot.subtitle = element_text(size = 8.85, colour = dark_grey, hjust = 0),
      plot.title.position = "plot",
      plot.margin = margin(5, 6, 5, 6)
    )
}

tag_theme <- theme(
  plot.tag = element_text(family = font_family, size = 8.45, face = "bold"),
  plot.tag.position = c(0, 1)
)

save_appendix <- function(plot, stem, height_mm) {
  width_in <- 183 / 25.4
  height_in <- height_mm / 25.4
  ggsave(
    file.path(figure_dir, paste0(stem, ".pdf")), plot,
    device = cairo_pdf, width = width_in, height = height_in,
    units = "in", bg = "white"
  )
  ragg::agg_tiff(
    file.path(figure_dir, paste0(stem, ".tiff")),
    width = width_in, height = height_in, units = "in", res = 300,
    compression = "lzw", background = "white"
  )
  print(plot)
  dev.off()
  ragg::agg_png(
    file.path(figure_dir, paste0(stem, ".png")),
    width = width_in, height = height_in, units = "in", res = 200,
    background = "white"
  )
  print(plot)
  dev.off()
}

comparison_labels <- c(
  corresponding_author = "Same author at the\nsame institution",
  topic_year = "Within subfield across years"
)

percent_ci_from_log <- function(effect, standard_error) {
  log_effect <- log1p(effect / 100)
  tibble(
    lower = 100 * (exp(log_effect - 1.96 * standard_error) - 1),
    upper = 100 * (exp(log_effect + 1.96 * standard_error) - 1)
  )
}

# Figure S1a: test whether same-author citations explain the pooled CJR result.
s1a_data <- read_csv(
  file.path(result_dir, "self_citation_sensitivity_results.csv"),
  show_col_types = FALSE
) %>%
  filter(universe == "full", analytic_field == "pooled") %>%
  mutate(
    comparison = factor(comparison_labels[model_level], levels = comparison_labels),
    sensitivity_label = recode(
      sensitivity,
      all_ties = "All citations",
      exclude_same_corresponding_author =
        "Remove same-author citations",
      complete_author_families_exclude_same =
        "Complete author data; remove\nsame-author citations"
    ),
    sensitivity_label = factor(
      sensitivity_label,
      levels = rev(c(
        "All citations",
        "Remove same-author citations",
        "Complete author data; remove\nsame-author citations"
      ))
    ),
    y_pos = as.numeric(sensitivity_label),
    estimate_label = sprintf("%.1f [%.1f, %.1f]",
                             percent_change_for_effj_doubling,
                             ci_low_percent, ci_high_percent)
  )

s1a <- ggplot(s1a_data,
              aes(x = percent_change_for_effj_doubling, y = y_pos)) +
  geom_vline(xintercept = 0, colour = dark_grey, linewidth = 0.4) +
  geom_errorbar(aes(xmin = ci_low_percent, xmax = ci_high_percent),
                orientation = "y", width = 0, linewidth = 0.7, colour = blue) +
  geom_point(size = 2.2, colour = blue) +
  geom_text(aes(y = y_pos + 0.20, label = estimate_label),
            family = font_family, size = 2.45, colour = ink) +
  facet_wrap(~comparison, nrow = 1) +
  scale_y_continuous(breaks = 1:3, labels = levels(s1a_data$sensitivity_label),
                     limits = c(0.65, 3.48)) +
  scale_x_continuous(limits = c(-8.0, 1.4), breaks = c(-8, -6, -4, -2, 0)) +
  labs(
    x = "Percent change in CJR when EffJ doubles",
    y = NULL,
    title = "Do citations by the same author explain the result?"
  ) +
  theme_appendix()

# Figure S1b: test whether any shared author between a paper pair explains the result.
s1b_data <- read_csv(
  file.path(result_dir, "pair_level_self_citation_sensitivity.csv"),
  show_col_types = FALSE
) %>%
  filter(universe == "full") %>%
  mutate(
    taxonomy = recode(exposure,
                      openalex_log_eff_j = "Primary OpenAlex labels",
                      text_log_eff_j = "Title-abstract-only clusters"),
    overlap_rule = recode(
      sensitivity,
      all_pairs_control_author_overlap = "Control for shared authors",
      exclude_any_author_overlap = "Remove all shared-author pairs"
    ),
    taxonomy = factor(taxonomy,
                      levels = c("Primary OpenAlex labels",
                                 "Title-abstract-only clusters")),
    overlap_rule = factor(overlap_rule, levels = rev(c(
      "Control for shared authors",
      "Remove all shared-author pairs"
    ))),
    y_pos = as.numeric(overlap_rule),
    cjr_effect = 100 * ((1 + rate_ratio_change_percent_for_effj_doubling / 100)^(-1) - 1),
    cjr_lower = 100 * ((1 + ci_high_percent / 100)^(-1) - 1),
    cjr_upper = 100 * ((1 + ci_low_percent / 100)^(-1) - 1),
    estimate_label = sprintf("%.1f [%.1f, %.1f]",
                             cjr_effect, cjr_lower, cjr_upper)
  )

s1b <- ggplot(s1b_data,
              aes(x = cjr_effect, y = y_pos)) +
  geom_vline(xintercept = 0, colour = dark_grey, linewidth = 0.4) +
  geom_errorbar(aes(xmin = cjr_lower, xmax = cjr_upper),
                orientation = "y", width = 0, linewidth = 0.7, colour = orange) +
  geom_point(size = 2.2, colour = orange) +
  geom_text(aes(y = y_pos + 0.20, label = estimate_label),
            family = font_family, size = 2.40, colour = ink) +
  facet_wrap(~taxonomy, nrow = 1) +
  scale_y_continuous(breaks = 1:2, labels = levels(s1b_data$overlap_rule),
                     limits = c(0.65, 2.42)) +
  scale_x_continuous(limits = c(-16.5, 1.0), breaks = c(-15, -10, -5, 0)) +
  labs(
    x = "Percent change in CJR when EffJ doubles",
    y = NULL,
    title = "Does any shared author explain the result?"
  ) +
  theme_appendix()

# Figure S1c: decompose the CJR result into within- and across-journal rates.
# The across-journal outcome contains no journal self-citations by construction.
s1c_data <- read_csv(
  "results/six_field_analysis/researcher_portfolio_windows_fe_results.csv",
  show_col_types = FALSE
) %>%
  filter(
    universe == "full",
    analytic_field == "pooled",
    outcome %in% c(
      "portfolio_within_journal_tie_density_pp",
      "portfolio_cross_journal_tie_density_pp"
    ),
    horizon %in% c(2, 3, 5)
  ) %>%
  mutate(
    boundary = recode(
      outcome,
      portfolio_within_journal_tie_density_pp = "Within journal",
      portfolio_cross_journal_tie_density_pp = "Across journals"
    ),
    row_label = paste0(horizon, " years: ", str_to_lower(boundary)),
    row_label = factor(
      row_label,
      levels = rev(c(
        "2 years: within journal", "2 years: across journals",
        "3 years: within journal", "3 years: across journals",
        "5 years: within journal", "5 years: across journals"
      ))
    ),
    row_number = as.numeric(row_label),
    lower = estimate_doubling - 1.96 * standard_error_doubling,
    upper = estimate_doubling + 1.96 * standard_error_doubling,
    estimate_label = sprintf("%.2f [%.2f, %.2f]",
                             estimate_doubling, lower, upper)
  )

s1c <- ggplot(s1c_data, aes(x = estimate_doubling, y = row_number, colour = boundary)) +
  geom_vline(xintercept = 0, colour = dark_grey, linewidth = 0.4) +
  geom_errorbar(aes(xmin = lower, xmax = upper), orientation = "y",
                width = 0, linewidth = 0.7) +
  geom_point(size = 2.2) +
  geom_text(aes(y = row_number + 0.19, label = estimate_label),
            family = font_family, size = 2.40, colour = ink) +
  scale_colour_manual(values = c("Within journal" = orange, "Across journals" = green),
                      guide = "none") +
  scale_y_continuous(
    breaks = seq_along(levels(s1c_data$row_label)),
    labels = levels(s1c_data$row_label),
    limits = c(0.65, 6.55)
  ) +
  scale_x_continuous(limits = c(-0.45, 0.82),
                     breaks = c(-0.4, 0, 0.4, 0.8)) +
  labs(
    x = "Citation-rate change when EffJ doubles (percentage points)",
    y = NULL,
    title = "Within-journal increase and across-journal decrease",
    subtitle = "Across-journal estimates contain no journal self-citations"
  ) +
  theme_appendix()

figure_s1 <- s1a / s1b / s1c +
  plot_layout(heights = c(0.78, 0.68, 0.68)) +
  plot_annotation(tag_levels = "a", theme = tag_theme)
save_appendix(figure_s1, "figure_s1_self_citation_full_openalex", 180)

# Figure S2a: mutually exclusive primary labels versus a text-only taxonomy.
s2a_data <- read_csv(
  file.path(result_dir, "assignment_sensitivity_results.csv"),
  show_col_types = FALSE
) %>%
  filter(universe == "full") %>%
  mutate(
    comparison = factor(comparison_labels[model_level], levels = comparison_labels),
    assignment_label = recode(
      assignment,
      `OpenAlex primary topic and primary field` = "Primary OpenAlex labels",
      `Title-abstract-only 256-cluster taxonomy` = "Title-abstract-only clusters"
    ),
    assignment_label = factor(
      assignment_label,
      levels = c("Primary OpenAlex labels", "Title-abstract-only clusters")
    ),
    y_pos = as.numeric(assignment_label),
    estimate_label = sprintf("%.1f [%.1f, %.1f]",
                             effect_percent, ci_low_percent, ci_high_percent)
  )

s2a <- ggplot(s2a_data, aes(x = effect_percent, y = y_pos)) +
  geom_vline(xintercept = 0, colour = dark_grey, linewidth = 0.4) +
  geom_errorbar(aes(xmin = ci_low_percent, xmax = ci_high_percent),
                orientation = "y", width = 0, linewidth = 0.7, colour = blue) +
  geom_point(size = 2.2, colour = blue) +
  geom_text(aes(y = y_pos + 0.19, label = estimate_label),
            family = font_family, size = 2.40, colour = ink) +
  facet_wrap(~comparison, nrow = 1) +
  scale_y_continuous(breaks = 1:2, labels = levels(s2a_data$assignment_label),
                     limits = c(0.68, 2.42)) +
  scale_x_continuous(limits = c(-8, 1.4), breaks = c(-8, -6, -4, -2, 0)) +
  labs(
    x = "Percent change in CJR when EffJ doubles",
    y = NULL,
    title = "Primary labels versus an independent text taxonomy"
  ) +
  theme_appendix()

make_text_taxonomy_results <- function(path, field_column, comparison_name) {
  raw <- read_csv(path, show_col_types = FALSE)
  field_values <- raw[[field_column]]
  ci <- percent_ci_from_log(raw$percent_change_for_effj_doubling,
                            raw$standard_error_log_rate_doubling)
  raw %>%
    mutate(
      raw_field = field_values,
      type = if_else(str_starts(raw_field, "exclude_"),
                     "Leave one field out", "Field-specific"),
      display_field = str_remove(raw_field, "^exclude_"),
      field = factor(clean_field(display_field), levels = rev(field_order)),
      comparison = comparison_name,
      lower = ci$lower,
      upper = ci$upper
    ) %>%
    filter(universe == "full", raw_field != "pooled")
}

s2b_data <- bind_rows(
  make_text_taxonomy_results(
    file.path(result_dir, "text_only_researcher_fe_results.csv"),
    "analytic_field", comparison_labels[["corresponding_author"]]
  ),
  make_text_taxonomy_results(
    file.path(result_dir, "text_only_coordination_fe_results.csv"),
    "scope_name", comparison_labels[["topic_year"]]
  )
) %>%
  mutate(
    type = factor(type, levels = c("Field-specific", "Leave one field out")),
    comparison = factor(comparison, levels = comparison_labels),
    row_label = if_else(type == "Leave one field out",
                        paste0("Exclude ", field), as.character(field)),
    row_label = factor(
      row_label,
      levels = rev(c(field_order, paste0("Exclude ", field_order)))
    ),
    y_pos = as.numeric(row_label),
    estimate_label = sprintf("%.1f [%.1f, %.1f]",
                             percent_change_for_effj_doubling, lower, upper)
  )

s2b <- ggplot(s2b_data,
              aes(x = percent_change_for_effj_doubling, y = y_pos)) +
  geom_vline(xintercept = 0, colour = dark_grey, linewidth = 0.4) +
  geom_hline(yintercept = 6.5, colour = dark_grey, linewidth = 0.45,
             linetype = "dashed") +
  geom_errorbar(aes(xmin = lower, xmax = upper), orientation = "y",
                width = 0, linewidth = 0.6, colour = blue) +
  geom_point(size = 1.9, colour = blue) +
  facet_wrap(~comparison, nrow = 1) +
  scale_y_continuous(breaks = 1:12, labels = levels(s2b_data$row_label),
                     limits = c(0.65, 12.35)) +
  scale_x_continuous(limits = c(-19, 6), breaks = c(-15, -10, -5, 0, 5)) +
  labs(
    x = "Percent change in CJR when EffJ doubles",
    y = NULL,
    title = "Field-specific and leave-one-field-out estimates"
  ) +
  theme_appendix()

# Figure S2c: account for papers assigned to more than one OpenAlex topic.
s2c_data <- read_csv(
  file.path(result_dir, "pair_level_boundary_ppml_results.csv"),
  show_col_types = FALSE
) %>%
  filter(universe == "full", specification == "controlled") %>%
  mutate(
    taxonomy = recode(exposure,
                      openalex_log_eff_j = "Primary OpenAlex labels",
                      text_log_eff_j = "Title-abstract-only clusters"),
    taxonomy = factor(taxonomy,
                      levels = rev(c("Primary OpenAlex labels",
                                     "Title-abstract-only clusters"))),
    log_effect = log1p(rate_ratio_change_percent_for_effj_doubling / 100),
    inverse_lower = 100 * (exp(log_effect - 1.96 * standard_error_log_rate_doubling) - 1),
    inverse_upper = 100 * (exp(log_effect + 1.96 * standard_error_log_rate_doubling) - 1),
    cjr_effect = 100 * ((1 + rate_ratio_change_percent_for_effj_doubling / 100)^(-1) - 1),
    lower = 100 * ((1 + inverse_upper / 100)^(-1) - 1),
    upper = 100 * ((1 + inverse_lower / 100)^(-1) - 1),
    y_pos = as.numeric(taxonomy),
    estimate_label = sprintf("%.1f [%.1f, %.1f]",
                             cjr_effect,
                             lower, upper)
  )

s2c <- ggplot(s2c_data,
              aes(x = cjr_effect, y = y_pos)) +
  geom_vline(xintercept = 0, colour = dark_grey, linewidth = 0.4) +
  geom_errorbar(aes(xmin = lower, xmax = upper), orientation = "y",
                width = 0, linewidth = 0.7, colour = orange) +
  geom_point(size = 2.2, colour = orange) +
  geom_text(aes(y = y_pos + 0.19, label = estimate_label),
            family = font_family, size = 2.40, colour = ink) +
  scale_y_continuous(breaks = 1:2, labels = levels(s2c_data$taxonomy),
                     limits = c(0.68, 2.42)) +
  scale_x_continuous(limits = c(-8.5, 1.0), breaks = c(-8, -6, -4, -2, 0)) +
  labs(
    x = "Percent change in CJR when EffJ doubles",
    y = NULL,
    title = "Accounting for papers assigned to multiple topics"
  ) +
  theme_appendix()

figure_s2 <- s2a / s2b / s2c +
  plot_layout(heights = c(0.65, 1.35, 0.65)) +
  plot_annotation(tag_levels = "a", theme = tag_theme)
save_appendix(figure_s2, "figure_s2_assignment_full_openalex", 220)

# Figure S3: Full OpenAlex and SCImago-matched source universes.
s3_data <- bind_rows(
  bind_rows(
    read_csv(
      file.path(result_dir, "temporal_researcher_coordination_fe_results.csv"),
      show_col_types = FALSE
    ) %>%
      filter(specification == "context_controls", analytic_field == "pooled") %>%
      mutate(model_level = "corresponding_author"),
    read_csv(
      file.path(result_dir, "temporal_coordination_fe_results.csv"),
      show_col_types = FALSE
    ) %>%
      filter(specification == "context_controls", analytic_field == "pooled") %>%
      mutate(model_level = "topic_year")
  ) %>%
    bind_cols(percent_ci_from_log(
      .$percent_change_for_effj_doubling,
      .$standard_error_log_rate_doubling
    )) %>%
    transmute(
      model_level, universe,
      specification = "Context-adjusted primary model",
      effect = percent_change_for_effj_doubling,
      lower, upper
    ),
  read_csv(file.path(result_dir, "self_citation_sensitivity_results.csv"),
           show_col_types = FALSE) %>%
    filter(analytic_field == "pooled", sensitivity != "all_ties") %>%
    transmute(
      model_level, universe,
      specification = recode(
        sensitivity,
        exclude_same_corresponding_author = "Remove same-author citations",
        complete_author_families_exclude_same =
          "Complete author coverage"
      ),
      effect = percent_change_for_effj_doubling,
      lower = ci_low_percent,
      upper = ci_high_percent
    ),
  read_csv(file.path(result_dir, "assignment_sensitivity_results.csv"),
           show_col_types = FALSE) %>%
    filter(assignment == "Title-abstract-only 256-cluster taxonomy") %>%
    transmute(
      model_level, universe,
      specification = "Title-abstract-only clusters",
      effect = effect_percent,
      lower = ci_low_percent,
      upper = ci_high_percent
    )
) %>%
  mutate(
    comparison = factor(comparison_labels[model_level], levels = comparison_labels),
      specification = factor(
      specification,
      levels = rev(c(
        "Context-adjusted primary model",
        "Remove same-author citations",
        "Complete author coverage",
        "Title-abstract-only clusters"
      ))
    ),
    y_pos = as.numeric(specification) + if_else(universe == "full", 0.10, -0.10),
    universe_label = recode(universe,
                            full = "Full OpenAlex",
                            scimago = "SCImago-matched")
  )

s3 <- ggplot(s3_data, aes(x = effect, y = y_pos, colour = universe_label)) +
  geom_vline(xintercept = 0, colour = dark_grey, linewidth = 0.4) +
  geom_errorbar(aes(xmin = lower, xmax = upper), orientation = "y",
                width = 0, linewidth = 0.65) +
  geom_point(size = 2.1) +
  facet_wrap(~comparison, nrow = 1) +
  scale_y_continuous(breaks = 1:4, labels = levels(s3_data$specification),
                     limits = c(0.60, 4.45)) +
  scale_x_continuous(limits = c(-15, 1.4), breaks = c(-12, -8, -4, 0)) +
  scale_colour_manual(values = c("Full OpenAlex" = blue,
                                 "SCImago-matched" = orange)) +
  labs(
    x = "Percent change in CJR when EffJ doubles",
    y = NULL,
    title = "Full OpenAlex and SCImago-matched results"
  ) +
  theme_appendix()

figure_s3 <- s3 + plot_annotation(theme = tag_theme)
save_appendix(figure_s3, "figure_s3_scimago_universe_robustness", 105)

cat("Rendered three appendix figures.\n")
