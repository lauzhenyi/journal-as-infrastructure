# Source Code

This directory contains the research source code used to collect and prepare
the data, estimate the main models, run the appendix analyses, and produce the
reported figures and tables for the journal-structure study.

The numbering is the analysis order. The repository is not designed as a
one-command pipeline because the original work ran across Google BigQuery,
Google Colab, and a high-memory local environment. Each file preserves the
paths and output locations used in the original run, except where a
command-line project-root argument has been added for a portable release.

## Numbering convention

Files use `SS_NN_action.ext`, where `SS` is the stage and `NN` is the order
within that stage. Run stages from `01` through `06`. Within a stage, data
builders normally precede estimators, and estimators precede renderers.

| Stage | Research step | Main contents |
|---|---|---|
| `01` | Data acquisition | OpenAlex extraction, cleaning, and SPECTER2 embeddings |
| `02` | Prepared database | Analysis tables, citation families, EffJ, and validation |
| `03` | Main analysis | Topic-year and corresponding-author CJR models |
| `04` | Later uptake | Early cross-journal share, later citations, and joint models |
| `05` | Appendix analyses | Alternative classifications, pair controls, placebo tests, and sensitivities |
| `06` | Reporting | Sample tables, audits, and manuscript figure rendering |

## Directory order

```text
01_data_acquisition/    OpenAlex extraction, cleaning, and embeddings
02_prepared_database/   Analysis-database preparation and validation
03_main_analysis/       Topic-year and corresponding-author models
04_later_citations/     Later citations to intermediate papers
05_robustness_checks/   Alternative explanations and sensitivity analyses
06_figure_and_reporting/ Descriptives, audits, and figure rendering
```

## 01. Data acquisition and shared preprocessing

These files are exact copies of the shared code in `core_peripheral`.

### `01_01_extract_openalex_bigquery.sql`

- Environment: Google BigQuery.
- Input: `nber-i3.openalex.works_20260203`.
- Selects the six OpenAlex fields used by the study.
- Creates work-level staging tables containing publication, journal, topic,
  authorship, institution, citation, open-access, and text fields.

### `01_02_build_analytic_openalex_tables.sql`

- Environment: Google BigQuery.
- Input: the staging tables created by `01_01`.
- Creates cleaned work, field, author, author-institution, topic, reference,
  and text tables.
- These tables were exported to Parquet under
  `/Volumes/Extreme SSD/openalex_20260203`.

Exporting these tables to the documented Parquet layout is an operational
data-transfer step and is not treated as a separate analysis stage.

### `01_03_prepare_specter2_bundle.py`

- Environment: local Python.
- Inputs: `analytic_work_text` and `analytic_work_field` Parquet files.
- Packages titles, abstracts, work identifiers, and field information for
  Google Colab.

### `01_04_generate_specter2_embeddings_colab.ipynb`

- Environment: Google Colab.
- Input: the bundle created by `01_03`.
- Generates SPECTER2 embeddings and their work-index files.

### `01_05_restore_validate_embeddings.py`

- Environment: local Python.
- Restores the Colab outputs to
  `/Volumes/Extreme SSD/openalex_20260203/embeddings/output_embeddings`.
- Validates row counts, work identifiers, dimensions, and shard coverage.

The embeddings are used only by the direct paper-pair robustness checks in
`05_08`. They do not define the main topic-year exposure or outcome.

The `core_peripheral` coauthorship-network, MKE, core-position, and later
analysis files are not inputs to this study and are therefore not included.

## 02. Prepared analysis database

Set `JOURNAL_STRUCTURE_DATABASE` for files that support a database-path
override. Other copied files retain the original absolute path.

### `02_01_prepare_scimago_roster.py`

- Reads the fixed SCImago journal roster and the OpenAlex source table.
- Normalizes ISSNs and creates `sjr_sources`, the source-ID roster used to
  distinguish the full and SCImago-matched universes.

### `02_02_build_core_article_tables.py`

- Reads the cleaned OpenAlex work, authorship, and institution Parquet files.
- Creates `six_base`, `corresponding_author`, `corresponding_institution`,
  `paper_universes`, `journal_exposure`, and `analysis_articles`.
- Defines the six fields, publication cohorts, citation windows, EffJ, selected
  corresponding author and institution, and field-year identifiers.

### `02_03_build_journal_topic_year_counts.py`

- Creates `journal_topic_year_counts_six` from `paper_universes`.
- Retains the table-building section used by the numbered analyses; the
  unrelated journal entry/exit branch from the original source is excluded.

### `02_04_build_citation_families.py`

- Reads cleaned works and citation edges.
- Creates eligible follow-on works, focal citation families, realized
  within-family citation pairs, fixed-horizon family and pair tables, and
  `conversation_outcomes_six`.

### `02_05_build_citer_metadata.py`

- Adds OpenAlex topic, field, and domain metadata for citing works.
- Selects corresponding authors and institutions for citing works.
- Creates `citer_intellectual_metadata_six`,
  `citer_corresponding_institution_six`, `attention_member_six`, and the
  supporting attention summaries.

### `02_06_build_scimago_annual_sjr.py`

- Standardizes annual SCImago CSV files.
- Normalizes ISSNs and links annual SJR values to OpenAlex source identifiers.
- Creates `scimago_annual_sjr_source_six`.
- The executed source also contains an archived early-citation branch; only the
  annual SCImago table is required by the retained analysis.

### `02_07_build_corresponding_author_panels.py`

- Inputs: `analysis_articles`, `attention_member_six`, and corresponding-author
  and institution tables.
- Creates the corresponding-author cohort, attention summaries, and
  `researcher_attention_panel_six`.

### `02_08_build_alternative_journal_measures.py`

- Creates journal-count and entropy alternatives to EffJ.
- Creates `journal_exposure_alternatives_six` for `02_09`.

### `02_09_build_effj_control_tables.py`

- Combines EffJ with journal-topic-year counts and alternative journal
  measures.
- Creates `robust_topic_exposure_six`, including the current EffJ measure and
  the retained controls used by the main models.

### `02_10_validate_prepared_database.py`

- Opens the DuckDB in read-only mode.
- Checks required upstream tables, language coverage, and citation-pair count
  constraints.

### `02_11_prepared_database_inventory.csv`

Records table names, row counts, column counts, and roles from the archived
DuckDB.

### `02_12_prepared_database_schema.sql`

Records the column schemas of the required upstream tables.

### Recovered source provenance

The one-off sources now numbered `02_01`, `02_02`, `02_04`, and `02_05` were
recovered from the original Codex session patch records. They preserve the
contents of the temporary scripts used to create the archived DuckDB tables.
`02_03`, `02_08`, and `02_09` retain only the table-building sections used by
the numbered analyses; unrelated branches from their original source files
are not included. `ORIGIN_MANIFEST.csv` records the source of each file.

## 03. Main analysis

### `03_01_build_topic_year_citation_pairs.py`

- Inputs: prepared citation-family tables, article records, EffJ controls, and
  annual SJR.
- Keeps later-paper groups with 2-20 papers and reliable publication dates.
- Counts possible and actual same-journal and different-journal citations.
- Aggregates the counts to topic-year panels.
- Output:
  `results/direct_outcome_gap/temporal_coordination_topic_year.parquet`.

### `03_02_estimate_topic_year_models.R`

- Input: the topic-year panel from `03_01`.
- Estimates pooled, field-specific, leave-one-field-out, and controlled
  current-EffJ models.
- Uses the number of possible citations as the model exposure.
- Output:
  `results/direct_outcome_gap/temporal_coordination_fe_results.csv`.

The change-based and lead-placebo checks are numbered `05_16` and `05_25`.

### `03_03_build_corresponding_author_citation_pairs.py`

- Inputs: corresponding-author cohorts, prepared citation pairs, and EffJ
  controls.
- Builds same-journal and different-journal citation counts for each author,
  institution, broad field, and publication cohort.
- Output:
  `results/direct_outcome_gap/temporal_researcher_coordination.parquet`.

### `03_04_estimate_corresponding_author_models.R`

- Input: the corresponding-author panel from `03_03`.
- Estimates pooled, field-specific, leave-one-field-out, and controlled
  current-EffJ models.
- Output:
  `results/direct_outcome_gap/temporal_researcher_coordination_fe_results.csv`.

### `03_05_build_two_three_five_year_rates.py`

- Builds separate same-journal and different-journal citation rates for two-,
  three-, and five-year windows.
- Intermediate output:
  `/private/tmp/researcher_portfolio_integration_windows_six.parquet`.

### `03_06_estimate_two_three_five_year_rates.R`

- Input: the window panel from `03_05`.
- Estimates the separate citation-rate models with author, institution,
  field-year, and later-paper-count controls.
- Output:
  `results/six_field_analysis/researcher_portfolio_windows_fe_results.csv`.

## 04. Later citations to intermediate papers

### `04_01_build_later_citation_panels.py`

- Defines early papers as years 1-3 after the starting paper.
- Defines later papers as years 4-5.
- Determines whether each later paper cites an eligible intermediate paper.
- Builds corresponding-author and topic-year panels.
- Outputs:
  - `results/cumulative_handoff/cumulative_handoff_family_panel.parquet`
  - `results/cumulative_handoff/cumulative_handoff_subfield_panel.parquet`

### `04_02_estimate_later_citation_models.R`

- Inputs: the two panels from `04_01`.
- Estimates pooled, field-specific, and leave-one-field-out models.
- Output: `results/cumulative_handoff/cumulative_handoff_results.csv`.

### `04_03_estimate_joint_effj_cjr_handoff.R`

- Uses the common subfield sample to estimate the EffJ, early CJR, and later
  cross-journal uptake pathway.
- Estimates pooled and field-specific results in Full OpenAlex and the
  SCImago-matched universe.
- Output: `results/cumulative_handoff/joint_effj_cjr_handoff_results.csv`.

### `04_04_bootstrap_joint_effj_cjr_handoff.R`

- Re-estimates the pooled joint pathway with topic-cluster bootstrap draws.
- Accepts the number of bootstrap repetitions as its command-line argument.
- Outputs the bootstrap draw and summary CSV files under
  `results/cumulative_handoff`.

### `04_05_estimate_later_uptake_cross_share.R`

- Uses the family panel from `04_01`.
- Models later uptake as a function of the early cross-versus-within citation
  odds while conditioning on total early ties and available early
  cross-versus-within opportunities.
- Uses corresponding-author and topic two-way clustered standard errors.
- Reports the pooled 2015-2021 estimate, the complete 2015-2020 cohort check,
  the SCImago-matched check, and field-specific estimates.
- Output:
  `results/cumulative_handoff/later_uptake_cross_share_results.csv`.

The current main later-uptake result is produced by `04_05`. The boundary-level
later-citation outcome used in the joint pathway is produced by `04_02`.

## 05. Robustness checks

### Alternative topics built from titles and abstracts

1. `05_01_build_title_abstract_topics.py` trains and assigns 256 text groups
   without citations, journals, OpenAlex topics, or OpenAlex subfields.
2. `05_02_estimate_title_abstract_topic_models.R` estimates the topic-year
   models using those groups.
3. `05_03_build_title_abstract_author_panels.py` builds the corresponding-
   author panels using those groups.
4. `05_04_estimate_title_abstract_author_models.R` estimates the corresponding-
   author models.
5. `05_05_build_title_abstract_later_citation_panels.py` rebuilds the years
   1-3 and years 4-5 panels using those groups.
6. `05_06_estimate_title_abstract_later_citation_models.R` estimates the later-
   citation models using those panels.

Outputs are stored in `results/direct_outcome_gap` and
`results/cumulative_handoff` with `text_only` or `text_taxonomy` in their file
names.

### Direct paper-pair controls

7. `05_07_build_semantic_coordination_members.py` builds the archived coarse
   text-cluster semantic-proximity mechanism panel. It is retained for source
   provenance but is outside the frozen paper specification registry.
8. `05_08_build_direct_paper_pair_controls.py` combines citation pairs with
   SPECTER2 similarity, shared references and topics, shared authors,
   institutions and countries, and publication-date distance. It creates
   `results/direct_outcome_gap/pair_level_boundary_pairs.parquet`.
9. `05_09_estimate_absolute_gap_and_curves.R` estimates absolute-gap models,
   field exclusions, descriptives, and similarity curves.
10. `05_10_estimate_pair_rate_models.R` estimates the relative citation-rate
   models.
11. `05_11_estimate_pair_odds_models.R` estimates binary citation-odds models.

### Random journal-label check

12. `05_12_run_random_journal_label_test.py` randomly reassigns journal labels
    within subject-year groups while preserving every journal-sized group. It
    writes the draw and summary CSV files under
    `results/direct_outcome_gap`.

### Self-citation, change, and similarity-selection checks

13. `05_13_build_self_citation_sensitivity.py` rebuilds the topic-year and
    corresponding-author panels with author self-citation indicators.
14. `05_14_estimate_self_citation_sensitivity.R` estimates the retained
    same-author-citation exclusions.
15. `05_15_estimate_pair_level_self_citation_sensitivity.R` controls for or
    removes any shared-author paper pair.
16. `05_16_estimate_cjr_change_models.R` estimates annual first differences
    and two- and three-year within-topic changes in EffJ and CJR.
17. `05_17_estimate_same_journal_similarity_selection.R` tests whether
    same-journal pair similarity or the same-versus-cross similarity gap rises
    with EffJ.

### No-upper-limit family-size sensitivity

18. `05_18_build_no_upper_limit_topic_year.py` removes the 20-paper upper
    bound, builds the shared family opportunities and realized ties, writes the
    topic-year panel, and records the contribution of 2-20 and 21+ families.
19. `05_19_estimate_no_upper_limit_topic_year.R` estimates the no-upper-limit
    same-subfield-and-year models.
20. `05_20_build_no_upper_limit_researcher.py` uses the shared no-upper-limit
    family tables to build the corresponding-author panel.
21. `05_21_estimate_no_upper_limit_researcher.R` estimates the no-upper-limit
    corresponding-author models.

The four files were reconstructed from the primary 2-20 scripts. The build and
validation status is documented in `REPRODUCTION_STATUS.md` and
`results/direct_outcome_gap/FIGURE_S4_REPRODUCIBILITY.md` in the parent
project.

### Independent-taxonomy separate-rate decomposition

22. `05_22_build_text_taxonomy_local_exchange.py` restricts the text-taxonomy
    corresponding-author panel to portfolios containing one focal paper and
    exports the within- and across-journal rate panel.
23. `05_23_estimate_text_taxonomy_local_exchange.R` estimates the two rates
    separately with author, institution, text-cluster, and field-year fixed
    effects. This check establishes that the relative CJR result survives the
    independent taxonomy even though the separate within-journal increase is
    not stable.

### Broad-field journals and timing diagnostics

24. `05_24_estimate_broad_field_journal_proxy.R` defines a broad-field journal
    roster using 2015-2021 output of at least 5,000 papers, at least five active
    years, at least three fields with both 500 papers and a 1% share, no field
    above 80%, and exclusion of conference series. It estimates the direct-pair
    model at minimum effective-field thresholds from 1.5 to 3.0.
25. `05_25_estimate_effj_lead_placebo.R` compares current EffJ, year-`t+1`
    EffJ, and a joint specification on the same topic-year sample.
26. `05_26_estimate_journal_pair_fe_diagnostic.R` adds unordered journal-pair
    fixed effects and reports the accompanying sample retention. This is a
    feasibility and selection diagnostic: journal pairs that cannot identify a
    fixed effect remove about 53% of the direct-pair sample, leaving a highly
    selected subset rather than the target population of the main analysis.

## 06. Descriptives, audits, and figures

1. `06_01_build_population_assignment_audit.py` compiles the retained
   population, author assignment, journal identity, and topic assignment
   checks.
2. `06_02_build_sample_descriptives.py` writes the sample-flow, analytic
   descriptive, later-uptake cohort, and model-sample-size tables. It labels
   the 8,417,036 field-assigned records as papers with author-institution
   assignment and separately records the 4,469,511 unique focal papers.
3. `06_03_build_main_figure_data.py` prepares the plotted data used by the
   main figures.
4. `06_04_render_main_figures.R` renders Figures 1-3, including the current
   early cross-versus-within citation-odds estimate in Figure 3b.
5. `06_05_render_figure_4_joint_model.R` renders the joint model and exact-count
   journal-label test as Figure 4.
6. `06_06_render_appendix_figures.R` renders the self-citation, assignment, and
   SCImago appendix figures.
7. `06_07_render_no_upper_limit_figure.R` renders the no-upper-limit family-size
   sensitivity figure from its retained CSV outputs.
8. `06_08_render_joint_path_figure.R` renders the standalone joint-path figure
   used by the later-uptake result archive.
9. `06_09_render_broad_field_journal_proxy.R` renders the appendix figure for
   the broad-field journal proxy estimates from `05_24`.

## Minimal execution order

1. Run `01_01`-`01_05` to create the cleaned OpenAlex exports and SPECTER2
   embeddings.
2. Run `02_01`-`02_10` to construct and validate the prepared DuckDB.
   Files `02_11` and `02_12` document the archived database rather than modify
   it.
3. Run `03_01`-`03_06` for the main CJR panels and estimates.
4. Run `04_01` before `04_02`-`04_05` for later-uptake analyses.
5. Run the required numbered checks in `05`; each builder is placed directly
   before its estimator. The pair-level checks require `05_08`, which in turn
   uses the SPECTER2 output from stage `01`.
6. Run `06_01`-`06_09` after the corresponding result files exist.

Large input data and generated result files are not included in this source
directory. Their expected locations are documented in the individual scripts.

`REPRODUCTION_STATUS.md` records the current Figure S4 validation status. The
source collection now includes the no-upper-limit panel and estimation
variants; the remaining check is to rerun them when the prepared DuckDB is
mounted and compare their outputs with the archived result CSV files.

## Software

The retained analysis was run with:

- Python 3.11.4
- DuckDB 1.5.4
- NumPy 2.3.5
- pandas 3.0.3
- PyArrow 24.0.0
- scikit-learn 1.9.0
- joblib 1.4.2
- R 4.6.0
- R arrow 24.0.0
- data.table 1.18.4
- fixest 0.14.1

The local builders use eight threads and generally set a 32 GB DuckDB memory
limit. The BigQuery and Colab stages require their respective hosted
environments.
