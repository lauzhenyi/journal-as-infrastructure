#!/usr/bin/env Rscript

# Estimate the direct-pair CJR association in broad-field journal proxy samples.

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(fixest)
  library(splines)
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
    "direct_outcome_gap",
    "broad_field_journal_proxy_results.csv"
  )
}

journal_cell_path <- file.path(
  project_root,
  "results",
  "openalex_replication",
  "prestige_journal_cells_3y.parquet"
)
pair_path <- file.path(
  project_root,
  "results",
  "direct_outcome_gap",
  "pair_level_boundary_pairs.parquet"
)

six_fields <- c(
  "Agricultural and Biological Sciences",
  "Chemistry",
  "Earth and Planetary Sciences",
  "Materials Science",
  "Medicine",
  "Physics and Astronomy"
)

# These OpenAlex sources are conference publication series rather than journals.
excluded_conference_sources <- paste0(
  "https://openalex.org/",
  c("S4210187594", "S2764696622")
)

journal_cells <- as.data.table(read_parquet(
  journal_cell_path,
  col_select = c(
    primary_field_name,
    publication_year,
    source_id,
    journal_n
  )
))
journal_cells <- journal_cells[primary_field_name %in% six_fields]

field_counts <- journal_cells[, .(
  papers = sum(journal_n)
), by = .(source_id, primary_field_name)]

journal_counts <- field_counts[, .(
  total_papers = sum(papers),
  largest_field_share = max(papers / sum(papers)),
  effective_fields = 1 / sum((papers / sum(papers))^2),
  qualifying_fields = sum(papers >= 500 & papers / sum(papers) >= 0.01)
), by = source_id]

active_years <- journal_cells[, .(
  active_years = uniqueN(publication_year[journal_n > 0])
), by = source_id]
journal_counts <- merge(journal_counts, active_years, by = "source_id")

base_roster <- journal_counts[
  total_papers >= 5000 &
    active_years >= 5 &
    qualifying_fields >= 3 &
    largest_field_share <= 0.80 &
    !source_id %in% excluded_conference_sources
]

pairs <- as.data.table(read_parquet(pair_path))[universe == "full"]
pairs[, `:=`(
  later_publication_year = as.character(as.integer(format(later_date, "%Y"))),
  focal_work_id = as.character(focal_work_id),
  focal_topic_id = as.character(focal_topic_id),
  log_date_distance = log1p(publication_date_distance_days)
)]

thresholds <- c(1.5, 2.0, 2.5, 3.0)

fit_threshold <- function(threshold) {
  roster <- base_roster[effective_fields >= threshold]
  roster_ids <- roster$source_id
  sample_data <- pairs[
    later_source_id %in% roster_ids | earlier_source_id %in% roster_ids
  ]

  model <- fepois(
    tie_count ~ same_journal + same_journal:openalex_log_eff_j +
      ns(cosine_similarity, df = 4) +
      bibliographic_coupling_cosine + shared_topic_jaccard +
      author_overlap + institution_overlap + country_overlap +
      ns(log_date_distance, df = 3) |
      focal_work_id + later_publication_year,
    data = sample_data,
    vcov = ~focal_topic_id,
    fixef.rm = "perfect_fit",
    notes = FALSE
  )

  term <- intersect(
    c(
      "same_journal:openalex_log_eff_j",
      "openalex_log_eff_j:same_journal"
    ),
    names(coef(model))
  )[[1]]
  coefficient <- coef(model)[[term]]
  standard_error <- se(model)[[term]]

  data.table(
    minimum_effective_fields = threshold,
    journal_count = nrow(roster),
    raw_pair_observations = nrow(sample_data),
    focal_families = uniqueN(sample_data$focal_work_id),
    same_journal_pairs = sum(sample_data$same_journal == 1L),
    realized_same_journal_citations = sum(
      sample_data$tie_count[sample_data$same_journal == 1L]
    ),
    model_observations = nobs(model),
    estimand = paste(
      "Percent change in reciprocal CJR for an EffJ doubling among pairs",
      "with at least one endpoint in the proxy-journal roster"
    ),
    cjr_change_percent_for_effj_doubling =
      100 * (exp(-coefficient * log(2)) - 1),
    confidence_low =
      100 * (exp(-(coefficient + 1.96 * standard_error) * log(2)) - 1),
    confidence_high =
      100 * (exp(-(coefficient - 1.96 * standard_error) * log(2)) - 1),
    p_value = pvalue(model)[[term]],
    definition = paste(
      "2015-2021 six-field output >=5,000 papers; >=5 active years;",
      ">=3 fields with >=500 papers and >=1% share; largest-field share",
      "<=80%; conference series excluded"
    )
  )
}

results <- rbindlist(lapply(thresholds, fit_threshold))
dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
fwrite(results, output_path)
print(results)
