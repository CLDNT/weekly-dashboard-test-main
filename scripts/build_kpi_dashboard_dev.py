"""
Build KPI Tracking Dashboard — Full Redesign v3

Filter architecture (updated 2026-07-09):
  - RelativeDateTime control per sheet, linked to RelativeDatesFilter (LAST 1 WEEK default)
  - RelativeDatesFilter (LAST 1 WEEK) as the user-facing period selector
  - TimeRangeFilter + RollingDate guard per sheet — excludes current in-progress week
    Expression: addDateTime(-7, 'WK', truncDate('WK', now())) → last Monday, IncludeMaximum=True
  - No TopBottomFilter (removed — KPI tiles average across ALL completed weeks in period)
  - No pWeekStart DateTimeParameterDeclaration / DateTimePicker controls

API constraints:
  - RelativeDatesFilter only accepts RelativeDateValue for LAST / NEXT types (not PREVIOUS)
  - LAST 1 WEEK = default to last completed Mon-Sun week
  - CrossDataset: SINGLE_DATASET required for RelativeDatesFilter and TimeRangeFilter

Sheets:
  1. OKR Scorecard    (kpi_snapshots: 8 KPI tiles, 2 trend charts, project health bar)
  2. Practice Scorecard (kpi_practice: 4 KPI tiles, 2 cross-practice bars, 2 trend lines)
  3. Staff Detail     (kpi_staff: 5 KPI tiles, compliance bar, util trend, staff table)
"""
import boto3
import time
import json

# ── Constants ─────────────────────────────────────────────────────────────────
PROFILE   = None  # Uses default AWS credentials (no named profile needed)
REGION    = 'us-east-1'
ACCOUNT   = '604775478093'
THEME_ARN = 'arn:aws:quicksight::aws:theme/CLASSIC'  # Using AWS default theme (no CE theme in this account)

SNAPSHOTS_DATASET_ID = 'kpi-weekly-snapshots-prod'
PRACTICE_DATASET_ID  = 'kpi-practice-weekly-prod'
STAFF_DATASET_ID     = 'kpi-staff-weekly-prod'
ANALYSIS_ID          = 'kpi-tracking-analysis-dev'
DASHBOARD_ID         = 'kpi-tracking-dashboard-dev'

OWNER_ARN = (
    'arn:aws:quicksight:us-east-1:604775478093:user/default/'
    'AWSReservedSSO_AdministratorAccess_9cc259e8fcbce348/haider.ahmed'
)
OWNER_ARN2 = OWNER_ARN  # Single owner in this account

# CE brand colors
CE_BLUE   = '#0089DD'
CE_PURPLE = '#27164F'
CE_GREEN  = '#33A94F'
CE_AMBER  = '#FF9B00'
CE_RED    = '#D74018'
WHITE     = '#FFFFFF'
GREY      = '#666666'

ANALYSIS_PERMISSIONS = [{'Principal': OWNER_ARN, 'Actions': [
    'quicksight:RestoreAnalysis','quicksight:UpdateAnalysisPermissions',
    'quicksight:DeleteAnalysis','quicksight:DescribeAnalysisPermissions',
    'quicksight:QueryAnalysis','quicksight:DescribeAnalysis','quicksight:UpdateAnalysis',
]}]

DASHBOARD_PERMISSIONS = [{'Principal': OWNER_ARN, 'Actions': [
    'quicksight:DescribeDashboard','quicksight:ListDashboardVersions',
    'quicksight:UpdateDashboardPermissions','quicksight:QueryDashboard',
    'quicksight:UpdateDashboard','quicksight:DeleteDashboard',
    'quicksight:DescribeDashboardPermissions','quicksight:UpdateDashboardPublishedVersion',
]}]


# ── Dataset identifier helper ──────────────────────────────────────────────────
def ds_ident(ds_id, identifier):
    return {
        'DataSetArn': f'arn:aws:quicksight:{REGION}:{ACCOUNT}:dataset/{ds_id}',
        'Identifier': identifier,
    }


# ── Layout grid item helper ────────────────────────────────────────────────────
def gi(elem_id, col, row, col_span, row_span, elem_type='VISUAL'):
    return {
        'ElementId': elem_id,
        'ElementType': elem_type,
        'ColumnIndex': col,
        'RowIndex': row,
        'ColumnSpan': col_span,
        'RowSpan': row_span,
    }


# ── Reference line (correct API shape) ────────────────────────────────────────
def ref_line(label, value, pattern='DASHED', color=GREY, series_type='LINE'):
    return {
        'Status': 'ENABLED',
        'DataConfiguration': {
            'StaticConfiguration': {'Value': float(value)},
            'AxisBinding': 'PRIMARY_YAXIS',
            'SeriesType': series_type,
        },
        'StyleConfiguration': {
            'Pattern': pattern,
            'Color': color,
        },
        'LabelConfiguration': {
            'CustomLabelConfiguration': {'CustomLabel': label},
            'FontConfiguration': {'FontSize': {'Relative': 'MEDIUM'}},
            'HorizontalPosition': 'RIGHT',
            'VerticalPosition': 'ABOVE',
        },
    }


# ── KPI visual (no top-level DataSetIdentifier) ────────────────────────────────
def kpi_visual(visual_id, ds_ident_name, measure_field_id, measure_col, agg, title,
               target_fid=None, target_col=None, target_agg='MAX',
               comparison=None):
    values = [{
        'NumericalMeasureField': {
            'FieldId': measure_field_id,
            'Column': {'DataSetIdentifier': ds_ident_name, 'ColumnName': measure_col},
            'AggregationFunction': {'SimpleNumericalAggregation': agg},
        }
    }]
    target_values = []
    if target_fid and target_col:
        target_values = [{
            'NumericalMeasureField': {
                'FieldId': target_fid,
                'Column': {'DataSetIdentifier': ds_ident_name, 'ColumnName': target_col},
                'AggregationFunction': {'SimpleNumericalAggregation': target_agg},
            }
        }]
    # KPIOptions: bare minimum to avoid API validation errors
    # Only add display properties when TargetValues/TrendGroups are present
    if target_fid and target_col:
        kpi_opts = {
            'PrimaryValueDisplayType': 'ACTUAL',
            'Sparkline': {'Visibility': 'HIDDEN', 'Type': 'LINE', 'TooltipVisibility': 'HIDDEN'},
        }
        kpi_opts['VisualLayoutOptions'] = {'StandardLayout': {'Type': 'VERTICAL'}}
    else:
        kpi_opts = {}
    if comparison and target_fid:
        kpi_opts['Comparison'] = {'ComparisonMethod': comparison}

    fw = {'Values': values}
    if target_values:
        fw['TargetValues'] = target_values

    return {
        'KPIVisual': {
            'VisualId': visual_id,
            'Title': {'Visibility': 'VISIBLE', 'FormatText': {'PlainText': title}},
            'ChartConfiguration': {
                'FieldWells': fw,
                'KPIOptions': kpi_opts,
            },
        }
    }


def kpi_count_distinct(visual_id, ds_ident_name, field_id, col, title):
    """KPI using COUNT_DISTINCT on a STRING column — must use CategoricalMeasureField."""
    return {
        'KPIVisual': {
            'VisualId': visual_id,
            'Title': {'Visibility': 'VISIBLE', 'FormatText': {'PlainText': title}},
            'ChartConfiguration': {
                'FieldWells': {
                    'Values': [{
                        'CategoricalMeasureField': {
                            'FieldId': field_id,
                            'Column': {'DataSetIdentifier': ds_ident_name, 'ColumnName': col},
                            'AggregationFunction': 'DISTINCT_COUNT',
                        }
                    }]
                },
                'KPIOptions': {},
            },
        }
    }


# ── Line chart ─────────────────────────────────────────────────────────────────
def line_chart(visual_id, ds_ident_name, x_fid, x_col, x_gran,
               y_series, title, ref_lines=None, colors=None):
    """
    y_series: list of {fid, col, agg} dicts
    colors: optional list of hex strings matching y_series order
    """
    cat = [{
        'DateDimensionField': {
            'FieldId': x_fid,
            'Column': {'DataSetIdentifier': ds_ident_name, 'ColumnName': x_col},
            'DateGranularity': x_gran,
        }
    }]
    vals = []
    for s in y_series:
        vals.append({
            'NumericalMeasureField': {
                'FieldId': s['fid'],
                'Column': {'DataSetIdentifier': ds_ident_name, 'ColumnName': s['col']},
                'AggregationFunction': {'SimpleNumericalAggregation': s['agg']},
            }
        })

    cfg = {
        'FieldWells': {
            'LineChartAggregatedFieldWells': {
                'Category': cat,
                'Values': vals,
            }
        },
        'Type': 'LINE',
    }
    if ref_lines:
        cfg['ReferenceLines'] = ref_lines
    if colors:
        cfg['VisualPalette'] = {
            'ChartColor': colors[0],
            'ColorMap': [
                {'FieldId': s['fid'], 'Color': c, 'Element': {'FieldId': s['fid'], 'FieldType': 'MEASURE'}}
                for s, c in zip(y_series, colors)
            ]
        }

    return {
        'LineChartVisual': {
            'VisualId': visual_id,
            'Title': {'Visibility': 'VISIBLE', 'FormatText': {'PlainText': title}},
            'ChartConfiguration': cfg,
        }
    }


# ── Horizontal bar chart ───────────────────────────────────────────────────────
def horiz_bar(visual_id, ds_ident_name, cat_fid, cat_col, val_fid, val_col, val_agg,
              title, ref_lines=None, drill_levels=None):
    """
    Single-level or hierarchical (drill-down) horizontal bar.

    drill_levels: optional list of (field_id, column_name) tuples defining a
    QuickSight in-visual drill hierarchy. The first tuple is the top level;
    users click a bar to drill into the next level.

    QuickSight drill-down on a bar chart is implemented via an ExplicitHierarchy
    in the visual's ColumnHierarchies, NOT by placing multiple fields in the
    Category field well (a bar chart's Category takes exactly one field). The
    single Category field is the top drill level; the hierarchy declares the
    full drill path. See BarChartVisual.column_hierarchies.
    """
    column_hierarchies = None
    if drill_levels:
        top_fid, top_col = drill_levels[0]
        cat = [{
            'CategoricalDimensionField': {
                'FieldId': top_fid,
                'Column': {'DataSetIdentifier': ds_ident_name, 'ColumnName': top_col},
                'HierarchyId': top_fid,
            }
        }]
        column_hierarchies = [{
            'ExplicitHierarchy': {
                'HierarchyId': top_fid,
                'Columns': [
                    {'DataSetIdentifier': ds_ident_name, 'ColumnName': col}
                    for _fid, col in drill_levels
                ],
            }
        }]
    else:
        cat = [{
            'CategoricalDimensionField': {
                'FieldId': cat_fid,
                'Column': {'DataSetIdentifier': ds_ident_name, 'ColumnName': cat_col},
            }
        }]
    val = [{
        'NumericalMeasureField': {
            'FieldId': val_fid,
            'Column': {'DataSetIdentifier': ds_ident_name, 'ColumnName': val_col},
            'AggregationFunction': {'SimpleNumericalAggregation': val_agg},
        }
    }]
    cfg = {
        'FieldWells': {
            'BarChartAggregatedFieldWells': {
                'Category': cat,
                'Values': val,
            }
        },
        'Orientation': 'HORIZONTAL',
        'BarsArrangement': 'CLUSTERED',
    }
    if ref_lines:
        cfg['ReferenceLines'] = ref_lines

    visual = {
        'VisualId': visual_id,
        'Title': {'Visibility': 'VISIBLE', 'FormatText': {'PlainText': title}},
        'ChartConfiguration': cfg,
    }
    if column_hierarchies:
        visual['ColumnHierarchies'] = column_hierarchies

    return {'BarChartVisual': visual}


# ── Stacked vertical bar chart ─────────────────────────────────────────────────
def stacked_bar(visual_id, ds_ident_name, x_fid, x_col, x_gran, val_series, title):
    """val_series: list of {fid, col, agg} dicts"""
    cat = [{
        'DateDimensionField': {
            'FieldId': x_fid,
            'Column': {'DataSetIdentifier': ds_ident_name, 'ColumnName': x_col},
            'DateGranularity': x_gran,
        }
    }]
    vals = []
    for s in val_series:
        vals.append({
            'NumericalMeasureField': {
                'FieldId': s['fid'],
                'Column': {'DataSetIdentifier': ds_ident_name, 'ColumnName': s['col']},
                'AggregationFunction': {'SimpleNumericalAggregation': s['agg']},
            }
        })
    return {
        'BarChartVisual': {
            'VisualId': visual_id,
            'Title': {'Visibility': 'VISIBLE', 'FormatText': {'PlainText': title}},
            'ChartConfiguration': {
                'FieldWells': {
                    'BarChartAggregatedFieldWells': {
                        'Category': cat,
                        'Values': vals,
                    }
                },
                'Orientation': 'VERTICAL',
                'BarsArrangement': 'STACKED',
            },
        }
    }


# ── Table visual (unaggregated) ────────────────────────────────────────────────
def table_unaggregated(visual_id, ds_ident_name, columns, title, header_bg=None):
    """columns: list of (field_id, col_name) tuples"""
    values = [
        {'FieldId': fid, 'Column': {'DataSetIdentifier': ds_ident_name, 'ColumnName': col}}
        for fid, col in columns
    ]
    table_opts = {}
    if header_bg:
        table_opts['HeaderStyle'] = {
            'BackgroundColor': header_bg,
            'TextWrap': 'WRAP',
            'FontConfiguration': {
                'FontColor': WHITE,
                'FontSize': {'Relative': 'SMALL'},
            },
        }
    return {
        'TableVisual': {
            'VisualId': visual_id,
            'Title': {'Visibility': 'VISIBLE', 'FormatText': {'PlainText': title}},
            'ChartConfiguration': {
                'FieldWells': {
                    'TableUnaggregatedFieldWells': {'Values': values}
                },
                'TableOptions': table_opts,
            },
        }
    }


# ── CategoryFilter helper ──────────────────────────────────────────────────────
def cat_filter(filter_id, ds_ident_name, col):
    return {
        'CategoryFilter': {
            'FilterId': filter_id,
            'Column': {'DataSetIdentifier': ds_ident_name, 'ColumnName': col},
            'Configuration': {
                'FilterListConfiguration': {
                    'MatchOperator': 'CONTAINS',
                    'SelectAllOptions': 'FILTER_ALL_VALUES',
                    'NullOption': 'ALL_VALUES',
                }
            }
        }
    }


# ── RelativeDatesFilter (LAST 1 WEEK — default = last completed week) ──────────
def relative_dates_filter(filter_id, ds_ident_name, col):
    """
    Period-selector filter linked to the RelativeDateTime control.
    Default: LAST 1 WEEK = last completed Mon-Sun week.
    QuickSight only accepts RelativeDateValue on LAST/NEXT types.
    """
    return {
        'RelativeDatesFilter': {
            'FilterId': filter_id,
            'Column': {'DataSetIdentifier': ds_ident_name, 'ColumnName': col},
            'AnchorDateConfiguration': {'AnchorOption': 'NOW'},
            'RelativeDateType':  'LAST',
            'RelativeDateValue': 2,
            'TimeGranularity':   'WEEK',
            'NullOption':        'ALL_VALUES',
        }
    }


# ── Completed-weeks guard (TimeRangeFilter + RollingDate) ─────────────────────
def completed_weeks_filter(filter_id, ds_ident_name, col):
    """
    Excludes the current in-progress week from all visuals.
    RollingDate upper bound = addDateTime(-7,'WK',truncDate('WK',now()))
      → start of last week (most recent Monday).
    IncludeMaximum=True → includes all rows where column <= last Monday,
      i.e. all completed weeks; the current week is always excluded.
    """
    return {
        'TimeRangeFilter': {
            'FilterId': filter_id,
            'Column': {'DataSetIdentifier': ds_ident_name, 'ColumnName': col},
            'RangeMaximumValue': {
                'RollingDate': {
                    'Expression':        "addDateTime(-1, 'WK', truncDate('WK', now()))",
                    'DataSetIdentifier': ds_ident_name,
                }
            },
            'NullOption':     'ALL_VALUES',
            'IncludeMaximum': True,
        }
    }


# ── FilterGroup builder ────────────────────────────────────────────────────────
def filter_group(fg_id, filter_obj, sheet_id, scope_visuals=None, cross_dataset='ALL_DATASETS'):
    if scope_visuals is None:
        scope = {
            'SelectedSheets': {
                'SheetVisualScopingConfigurations': [{
                    'SheetId': sheet_id,
                    'Scope': 'ALL_VISUALS',
                }]
            }
        }
    else:
        scope = {
            'SelectedSheets': {
                'SheetVisualScopingConfigurations': [{
                    'SheetId': sheet_id,
                    'Scope': 'SELECTED_VISUALS',
                    'VisualIds': scope_visuals,
                }]
            }
        }
    return {
        'FilterGroupId': fg_id,
        'Filters': [filter_obj],
        'ScopeConfiguration': scope,
        'Status': 'ENABLED',
        'CrossDataset': cross_dataset,
    }


# ── Filter controls ────────────────────────────────────────────────────────────
def dropdown_ctrl(ctrl_id, title, source_filter_id):
    return {
        'Dropdown': {
            'FilterControlId': ctrl_id,
            'Title': title,
            'SourceFilterId': source_filter_id,
            'Type': 'SINGLE_SELECT',
            'DisplayOptions': {
                'SelectAllOptions': {'Visibility': 'VISIBLE'},
            },
        }
    }


def relative_datetime_ctrl(ctrl_id, title, source_filter_id):
    return {
        'RelativeDateTime': {
            'FilterControlId': ctrl_id,
            'Title': title,
            'SourceFilterId': source_filter_id,
            'DisplayOptions': {
                'TitleOptions': {
                    'Visibility': 'VISIBLE',
                    'FontConfiguration': {'FontSize': {'Relative': 'MEDIUM'}},
                },
            },
        }
    }


# ── Calculated fields ──────────────────────────────────────────────────────────
CALCULATED_FIELDS = [
    {
        'DataSetIdentifier': 'kpi_snapshots',
        'Name': 'projects_red_pct',
        'Expression': '{total_projects_red} / nullIf(({total_projects_green} + {total_projects_amber} + {total_projects_red}), 0) * 100',
    },
    {
        'DataSetIdentifier': 'kpi_snapshots',
        'Name': 'current_quarter_otd_target',
        # QuickSight extract() uses double-quoted date part: extract("MM", {date})
        # Q1=1-3=45, Q2=4-6=60, Q3=7-9=75, Q4=10-12=90
        'Expression': 'ifelse(extract("MM",{week_start_date}) <= 3, 45, extract("MM",{week_start_date}) <= 6, 60, extract("MM",{week_start_date}) <= 9, 75, 90)',
    },
    {
        'DataSetIdentifier': 'kpi_practice',
        'Name': 'weighted_billable_util',
        'Expression': '{total_billable_hours} / nullIf({total_capacity_hours}, 0) * 100',
    },
    {
        'DataSetIdentifier': 'kpi_staff',
        'Name': 'compliance_pct_calc',
        'Expression': '{is_compliant} * 100',
    },
]


# ═══════════════════════════════════════════════════════════════════════════════
# SHEET 1 — OKR Scorecard
# ═══════════════════════════════════════════════════════════════════════════════
def build_sheet1():
    SID = 'sheet-kpi-s1'
    DS  = 'kpi_snapshots'

    tiles = [
        kpi_visual('kpi-s1-billable-util',  DS, 'ks-f1',  'billable_util_pct',        'MAX', 'Billable Utilization %',
                   target_fid='ks-f1t', target_col='target_billable_util_pct', comparison='DIFFERENCE'),
        kpi_visual('kpi-s1-productive-util',DS, 'ks-f2',  'productive_util_pct',       'MAX', 'Productive Utilization %'),
        kpi_visual('kpi-s1-compliance',     DS, 'ks-f3',  'time_compliance_pct',        'MAX', 'Timesheet Compliance %',
                   target_fid='ks-f3t', target_col='target_time_compliance_pct', comparison='DIFFERENCE'),
        kpi_visual('kpi-s1-ps-ontime',      DS, 'ks-f4',  'ps_on_time_pct',             'MAX', 'PS On-Time Delivery %',
                   target_fid='ks-f4t', target_col='current_quarter_otd_target', comparison='DIFFERENCE'),
        kpi_visual('kpi-s1-eng-duration',   DS, 'ks-f5',  'ps_avg_duration_weeks',      'MAX', 'Avg Engagement Duration (wks)',
                   target_fid='ks-f5t', target_col='target_ps_avg_duration_weeks', comparison='DIFFERENCE'),
        kpi_visual('kpi-s1-red-pct',        DS, 'ks-f6',  'projects_red_pct',           'MAX', 'Projects in Red %'),
        kpi_visual('kpi-s1-escalations',    DS, 'ks-f7',  'open_escalations',           'MAX', 'Open Escalations',
                   target_fid='ks-f7t', target_col='escalations_prev', comparison='DIFFERENCE'),
        kpi_visual('kpi-s1-resources',      DS, 'ks-f8',  'active_resource_count',      'MAX', 'Active Resources'),
        kpi_visual('kpi-s1-nb-nonprod',     DS, 'ks-f9',  'nb_nonproductive_hours',     'MAX', 'NB Non-Productive Hrs',
                   target_fid='ks-f9t', target_col='nb_nonproductive_prev', comparison='DIFFERENCE'),
    ]

    util_trend = line_chart(
        'chart-s1-util-trend', DS,
        x_fid='ks-xt1', x_col='week_start_date', x_gran='WEEK',
        y_series=[
            {'fid': 'ks-y1a', 'col': 'billable_util_pct',   'agg': 'MAX'},
            {'fid': 'ks-y1b', 'col': 'productive_util_pct', 'agg': 'MAX'},
            {'fid': 'ks-y1c', 'col': 'time_compliance_pct', 'agg': 'MAX'},
        ],
        title='Utilization & Compliance Trend',
        ref_lines=[
            ref_line('Billable 75%',   75, 'DASHED', GREY),
            ref_line('Productive 80%', 80, 'DASHED', GREY),
            ref_line('Compliance 95%', 95, 'DOTTED', CE_BLUE),
        ],
    )

    ontime_trend = line_chart(
        'chart-s1-ontime-trend', DS,
        x_fid='ks-xt2', x_col='week_start_date', x_gran='WEEK',
        y_series=[{'fid': 'ks-y2a', 'col': 'ps_on_time_pct', 'agg': 'MAX'}],
        title='PS On-Time Delivery Trend',
        ref_lines=[
            ref_line('Q3 Target 75%', 75, 'DASHED', GREY),
            ref_line('Q4 Target 90%', 90, 'DOTTED', CE_BLUE),
        ],
    )

    health_bar = stacked_bar(
        'bar-s1-health', DS,
        x_fid='ks-xb1', x_col='week_start_date', x_gran='WEEK',
        val_series=[
            {'fid': 'ks-hg', 'col': 'ps_projects_green', 'agg': 'SUM'},
            {'fid': 'ks-ha', 'col': 'ps_projects_amber', 'agg': 'SUM'},
            {'fid': 'ks-hr', 'col': 'ps_projects_red',   'agg': 'SUM'},
        ],
        title='Project Portfolio Health by Week (PS)',
    )

    visuals = tiles + [util_trend, ontime_trend, health_bar]

    layout_items = [
        gi('ctrl-s1-date',           28,  0,  8,  2, 'FILTER_CONTROL'),
        gi('kpi-s1-billable-util',    0,  2,  9,  4),
        gi('kpi-s1-productive-util',  9,  2,  9,  4),
        gi('kpi-s1-compliance',      18,  2,  9,  4),
        gi('kpi-s1-ps-ontime',       27,  2,  9,  4),
        gi('kpi-s1-eng-duration',     0,  6,  9,  4),
        gi('kpi-s1-red-pct',          9,  6,  9,  4),
        gi('kpi-s1-escalations',     18,  6,  9,  4),
        gi('kpi-s1-resources',       27,  6,  9,  4),
        gi('kpi-s1-nb-nonprod',       0, 10,  9,  4),
        gi('chart-s1-util-trend',     0, 14, 18, 12),
        gi('chart-s1-ontime-trend',  18, 14, 18, 12),
        gi('bar-s1-health',           0, 26, 36, 10),
    ]

    controls = [
        relative_datetime_ctrl('ctrl-s1-date', 'Reporting Period', 'fg-s1-date'),
    ]

    fg_date     = filter_group('fg-s1-date',     relative_dates_filter('fg-s1-date', DS, 'week_start_date'),    SID, cross_dataset='SINGLE_DATASET')
    fg_complete = filter_group('fg-s1-complete', completed_weeks_filter('fg-s1-complete', DS, 'week_start_date'), SID, cross_dataset='SINGLE_DATASET')

    sheet = {
        'SheetId': SID,
        'Name': 'OKR Scorecard',
        'FilterControls': controls,
        'Visuals': visuals,
        'Layouts': [{'Configuration': {'GridLayout': {
            'Elements': layout_items,
            'CanvasSizeOptions': {'ScreenCanvasSizeOptions': {'ResizeOption': 'FIXED', 'OptimizedViewPortWidth': '1600px'}},
        }}}],
    }
    return sheet, [fg_date]


# ═══════════════════════════════════════════════════════════════════════════════
# SHEET 2 — Practice Scorecard
# ═══════════════════════════════════════════════════════════════════════════════
def build_sheet2():
    SID = 'sheet-kpi-s2'
    DS  = 'kpi_practice'

    tiles = [
        kpi_visual('kpi-s2-headcount',  DS, 'kp-f1', 'headcount',            'SUM', 'Headcount'),
        kpi_visual('kpi-s2-hours',      DS, 'kp-f2', 'total_billable_hours',  'SUM', 'Total Billable Hours'),
        kpi_visual('kpi-s2-billable',   DS, 'kp-f3', 'weighted_billable_util','AVERAGE', 'Billable Utilization %'),
        kpi_visual('kpi-s2-compliance', DS, 'kp-f4', 'compliance_pct',        'AVERAGE', 'Timesheet Compliance %'),
    ]

    bar_util = horiz_bar(
        'bar-s2-util', DS, 'kp-bc1', 'practice_alignment', 'kp-bv1', 'weighted_billable_util', 'AVERAGE',
        'Billable Utilization % by Line of Business (drill to Practice)',
        ref_lines=[ref_line('Target 75%', 75, 'DASHED', GREY, 'BAR')],
        drill_levels=[('kp-bc1', 'line_of_business'), ('kp-bc1d', 'practice_alignment')],
    )
    bar_comp = horiz_bar(
        'bar-s2-compliance', DS, 'kp-bc2', 'practice_alignment', 'kp-bv2', 'compliance_pct', 'AVERAGE',
        'Compliance % by Line of Business (drill to Practice)',
        ref_lines=[ref_line('Target 95%', 95, 'DASHED', GREY, 'BAR')],
        drill_levels=[('kp-bc2', 'line_of_business'), ('kp-bc2d', 'practice_alignment')],
    )

    util_trend = line_chart(
        'chart-s2-util-trend', DS, 'kp-xt1', 'week_start', 'WEEK',
        y_series=[{'fid': 'kp-y1a', 'col': 'weighted_billable_util', 'agg': 'AVERAGE'}],
        title='Billable Utilization % Trend by Practice',
        ref_lines=[ref_line('Target 75%', 75, 'DASHED', GREY)],
    )
    comp_trend = line_chart(
        'chart-s2-compliance-trend', DS, 'kp-xt2', 'week_start', 'WEEK',
        y_series=[{'fid': 'kp-y2a', 'col': 'compliance_pct', 'agg': 'AVERAGE'}],
        title='Compliance % Trend by Line of Business',
        ref_lines=[ref_line('Target 95%', 95, 'DOTTED', CE_BLUE)],
    )

    visuals = tiles + [bar_util, bar_comp, util_trend, comp_trend]

    layout_items = [
        gi('ctrl-s2-date',             28,  0,  8,  2, 'FILTER_CONTROL'),
        gi('ctrl-s2-lob',               0,  0,  9,  2, 'FILTER_CONTROL'),
        gi('ctrl-s2-practice',          9,  0,  9,  2, 'FILTER_CONTROL'),
        gi('kpi-s2-headcount',          0,  2,  9,  4),
        gi('kpi-s2-hours',              9,  2,  9,  4),
        gi('kpi-s2-billable',          18,  2,  9,  4),
        gi('kpi-s2-compliance',        27,  2,  9,  4),
        gi('bar-s2-util',               0,  6, 18, 12),
        gi('bar-s2-compliance',        18,  6, 18, 12),
        gi('chart-s2-util-trend',       0, 18, 18, 12),
        gi('chart-s2-compliance-trend',18, 18, 18, 12),
    ]

    controls = [
        dropdown_ctrl('ctrl-s2-lob',      'Line of Business',  'fg-s2-lob'),
        dropdown_ctrl('ctrl-s2-practice', 'Practice Alignment','fg-s2-practice'),
        relative_datetime_ctrl('ctrl-s2-date', 'Reporting Period', 'fg-s2-date'),
    ]

    fg_lob      = filter_group('fg-s2-lob',      cat_filter('fg-s2-lob',      DS, 'line_of_business'),  SID)
    fg_practice = filter_group('fg-s2-practice',  cat_filter('fg-s2-practice', DS, 'practice_alignment'), SID)
    fg_date     = filter_group('fg-s2-date',      relative_dates_filter('fg-s2-date', DS, 'week_start'),     SID, cross_dataset='SINGLE_DATASET')
    fg_complete = filter_group('fg-s2-complete',  completed_weeks_filter('fg-s2-complete', DS, 'week_start'), SID, cross_dataset='SINGLE_DATASET')

    sheet = {
        'SheetId': SID,
        'Name': 'Practice Scorecard',
        'FilterControls': controls,
        'Visuals': visuals,
        'Layouts': [{'Configuration': {'GridLayout': {
            'Elements': layout_items,
            'CanvasSizeOptions': {'ScreenCanvasSizeOptions': {'ResizeOption': 'FIXED', 'OptimizedViewPortWidth': '1600px'}},
        }}}],
    }
    return sheet, [fg_lob, fg_practice, fg_date]


# ═══════════════════════════════════════════════════════════════════════════════
# SHEET 3 — Staff Detail
# ═══════════════════════════════════════════════════════════════════════════════
def build_sheet3():
    SID = 'sheet-kpi-s3'
    DS  = 'kpi_staff'

    tiles = [
        kpi_count_distinct('kpi-s3-headcount', DS, 'st-f1', 'user_name', 'Staff Count'),
        kpi_visual('kpi-s3-billable',   DS, 'st-f2', 'billable_util_pct',  'AVERAGE', 'Avg Billable Util %'),
        kpi_visual('kpi-s3-compliance', DS, 'st-f3', 'compliance_pct_calc','AVERAGE', 'Compliance %'),
        kpi_visual('kpi-s3-billhours',  DS, 'st-f4', 'billable_hours',     'SUM', 'Total Billable Hours'),
        kpi_visual('kpi-s3-ontime',     DS, 'st-f5', 'ontime_pct_in_week', 'AVERAGE', 'PS On-Time Delivery %'),
    ]

    bar_comp = horiz_bar(
        'bar-s3-compliance', DS, 'st-bc1', 'pod_assignment', 'st-bv1', 'compliance_pct_calc', 'AVERAGE',
        'Compliance % by Line of Business (drill to Practice \u2192 POD)',
        ref_lines=[ref_line('Target 95%', 95, 'DASHED', GREY, 'BAR')],
        drill_levels=[
            ('st-bc1', 'line_of_business'),
            ('st-bc1p', 'practice_alignment'),
            ('st-bc1d', 'pod_assignment'),
        ],
    )
    util_trend = line_chart(
        'chart-s3-util-trend', DS, 'st-xt1', 'week_start', 'WEEK',
        y_series=[{'fid': 'st-y1a', 'col': 'billable_util_pct', 'agg': 'AVERAGE'}],
        title='Billable Utilization % Trend',
        ref_lines=[ref_line('Target 75%', 75, 'DASHED', GREY)],
    )

    staff_cols = [
        ('tbl-s3-f0',  'line_of_business'),
        ('tbl-s3-f1',  'user_name'),
        ('tbl-s3-f2',  'practice_alignment'),
        ('tbl-s3-f3',  'pod_assignment'),
        ('tbl-s3-f4',  'cloudelligent_title'),
        ('tbl-s3-f5',  'week_start'),
        ('tbl-s3-f6',  'hours_logged'),
        ('tbl-s3-f7',  'billable_hours'),
        ('tbl-s3-f8',  'billable_util_pct'),
        ('tbl-s3-f14', 'nb_productive_hours'),
        ('tbl-s3-f15', 'nb_non_productive_hours'),
        ('tbl-s3-f16', 'productive_util_pct'),
        ('tbl-s3-f9',  'compliance_status'),
        ('tbl-s3-f10', 'projects_closed_in_week'),
        ('tbl-s3-f11', 'projects_on_time_in_week'),
        ('tbl-s3-f12', 'ontime_pct_in_week'),
        ('tbl-s3-f13', 'ontime_data_quality'),
    ]
    staff_table = table_unaggregated('tbl-s3-staff', DS, staff_cols, 'Staff KPI Detail', CE_PURPLE)

    visuals = tiles + [bar_comp, util_trend, staff_table]

    layout_items = [
        gi('ctrl-s3-date',      28,  0,  8,  2, 'FILTER_CONTROL'),
        gi('ctrl-s3-lob',        0,  0,  7,  2, 'FILTER_CONTROL'),
        gi('ctrl-s3-practice',   7,  0,  7,  2, 'FILTER_CONTROL'),
        gi('ctrl-s3-pod',       14,  0,  7,  2, 'FILTER_CONTROL'),
        gi('ctrl-s3-staff',     21,  0,  7,  2, 'FILTER_CONTROL'),
        gi('kpi-s3-headcount',   0,  2,  7,  4),
        gi('kpi-s3-billable',    7,  2,  7,  4),
        gi('kpi-s3-compliance', 14,  2,  7,  4),
        gi('kpi-s3-billhours',  21,  2,  7,  4),
        gi('kpi-s3-ontime',     28,  2,  8,  4),
        gi('bar-s3-compliance',  0,  6, 18, 12),
        gi('chart-s3-util-trend',18, 6, 18, 12),
        gi('tbl-s3-staff',       0, 18, 36, 18),
    ]

    controls = [
        dropdown_ctrl('ctrl-s3-lob',      'Line of Business',  'fg-s3-lob'),
        dropdown_ctrl('ctrl-s3-practice', 'Practice Alignment','fg-s3-practice'),
        dropdown_ctrl('ctrl-s3-pod',      'POD',               'fg-s3-pod'),
        dropdown_ctrl('ctrl-s3-staff',    'Individual',        'fg-s3-staff'),
        relative_datetime_ctrl('ctrl-s3-date', 'Reporting Period', 'fg-s3-date'),
    ]

    fg_lob      = filter_group('fg-s3-lob',      cat_filter('fg-s3-lob',      DS, 'line_of_business'),  SID)
    fg_practice = filter_group('fg-s3-practice',  cat_filter('fg-s3-practice', DS, 'practice_alignment'), SID)
    fg_pod      = filter_group('fg-s3-pod',       cat_filter('fg-s3-pod',      DS, 'pod_assignment'),    SID)
    fg_staff    = filter_group('fg-s3-staff',     cat_filter('fg-s3-staff',    DS, 'user_name'),         SID)
    fg_date     = filter_group('fg-s3-date',      relative_dates_filter('fg-s3-date', DS, 'week_start'),     SID, cross_dataset='SINGLE_DATASET')
    fg_complete = filter_group('fg-s3-complete',  completed_weeks_filter('fg-s3-complete', DS, 'week_start'), SID, cross_dataset='SINGLE_DATASET')

    sheet = {
        'SheetId': SID,
        'Name': 'Staff Detail',
        'FilterControls': controls,
        'Visuals': visuals,
        'Layouts': [{'Configuration': {'GridLayout': {
            'Elements': layout_items,
            'CanvasSizeOptions': {'ScreenCanvasSizeOptions': {'ResizeOption': 'FIXED', 'OptimizedViewPortWidth': '1600px'}},
        }}}],
    }
    return sheet, [fg_lob, fg_practice, fg_pod, fg_staff, fg_date]



# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════
def main():
    if PROFILE:
        session = boto3.Session(profile_name=PROFILE, region_name=REGION)
    else:
        session = boto3.Session(region_name=REGION)
    qs = session.client('quicksight')

    print('Building sheets...')
    s1, fg1 = build_sheet1()
    s2, fg2 = build_sheet2()
    s3, fg3 = build_sheet3()

    definition = {
        'DataSetIdentifierDeclarations': [
            ds_ident(SNAPSHOTS_DATASET_ID, 'kpi_snapshots'),
            ds_ident(PRACTICE_DATASET_ID,  'kpi_practice'),
            ds_ident(STAFF_DATASET_ID,     'kpi_staff'),
        ],
        'Sheets': [s1, s2, s3],
        'CalculatedFields': CALCULATED_FIELDS,
        'FilterGroups': fg1 + fg2 + fg3,
    }

    print(f'  Sheets: {len(definition["Sheets"])}')
    print(f'  FilterGroups: {len(definition["FilterGroups"])}')
    print(f'  CalculatedFields: {len(CALCULATED_FIELDS)}')

    # ── Create or update analysis ─────────────────────────────────────────────
    print(f'\nUpdating analysis {ANALYSIS_ID}...')
    try:
        existing = qs.describe_analysis(AwsAccountId=ACCOUNT, AnalysisId=ANALYSIS_ID)
        print(f'  Existing status: {existing["Analysis"]["Status"]}')
        resp = qs.update_analysis(
            AwsAccountId=ACCOUNT,
            AnalysisId=ANALYSIS_ID,
            Name='KPI Tracking Analysis (prod)',
            Definition=definition,
            ThemeArn=THEME_ARN,
        )
    except qs.exceptions.ResourceNotFoundException:
        print('  Not found — creating.')
        resp = qs.create_analysis(
            AwsAccountId=ACCOUNT,
            AnalysisId=ANALYSIS_ID,
            Name='KPI Tracking Analysis (prod)',
            Definition=definition,
            ThemeArn=THEME_ARN,
            Permissions=ANALYSIS_PERMISSIONS,
        )

    print(f'  HTTP {resp["ResponseMetadata"]["HTTPStatusCode"]}  Status: {resp.get("Status")}')

    # Poll for success
    print('  Polling analysis...')
    for attempt in range(36):
        time.sleep(5)
        r = qs.describe_analysis(AwsAccountId=ACCOUNT, AnalysisId=ANALYSIS_ID)
        astatus = r['Analysis']['Status']
        errors  = r['Analysis'].get('Errors', [])
        print(f'  [{attempt+1}] {astatus}' + (f' — {errors[0]["Message"][:80]}' if errors else ''))
        if 'SUCCESSFUL' in astatus:
            break
        if 'FAILED' in astatus:
            for e in errors:
                print(f'    {e.get("Type")}: {e.get("Message")}')
            raise RuntimeError(f'Analysis {astatus}')
    else:
        raise TimeoutError('Analysis timed out')

    # ── Publish dashboard ─────────────────────────────────────────────────────
    # Use Definition-based publish (same definition as analysis)
    print(f'\nPublishing dashboard {DASHBOARD_ID}...')
    dash_kwargs = dict(
        AwsAccountId=ACCOUNT,
        DashboardId=DASHBOARD_ID,
        Name='KPI Tracking Dashboard',
        Definition=definition,
        ThemeArn=THEME_ARN,
        DashboardPublishOptions={
            'AdHocFilteringOption': {'AvailabilityStatus': 'ENABLED'},
            'ExportToCSVOption':    {'AvailabilityStatus': 'ENABLED'},
        },
    )
    try:
        qs.describe_dashboard(AwsAccountId=ACCOUNT, DashboardId=DASHBOARD_ID)
        resp = qs.update_dashboard(**dash_kwargs)
    except qs.exceptions.ResourceNotFoundException:
        resp = qs.create_dashboard(Permissions=DASHBOARD_PERMISSIONS, **dash_kwargs)
    print(f'  HTTP {resp["ResponseMetadata"]["HTTPStatusCode"]}  Status: {resp.get("Status")}')

    print('  Polling dashboard...')
    vnum = 1
    for attempt in range(36):
        time.sleep(5)
        r = qs.describe_dashboard(AwsAccountId=ACCOUNT, DashboardId=DASHBOARD_ID)
        dstatus = r['Dashboard']['Version']['Status']
        vnum    = r['Dashboard']['Version']['VersionNumber']
        derrors = r['Dashboard']['Version'].get('Errors', [])
        print(f'  [{attempt+1}] {dstatus}  v{vnum}' + (f' — {derrors[0]["Message"][:80]}' if derrors else ''))
        if dstatus == 'CREATION_SUCCESSFUL':
            break
        if 'FAILED' in dstatus:
            for e in derrors:
                print(f'    {e.get("Type")}: {e.get("Message")}')
            raise RuntimeError(f'Dashboard {dstatus}')
    else:
        raise TimeoutError('Dashboard timed out')

    print(f'\nPublishing version {vnum}...')
    qs.update_dashboard_published_version(
        AwsAccountId=ACCOUNT, DashboardId=DASHBOARD_ID, VersionNumber=vnum,
    )

    print(f'\n✅ KPI dashboard rebuild complete — version {vnum}')
    print(f'   Dashboard: https://{REGION}.quicksight.aws.amazon.com/sn/dashboards/{DASHBOARD_ID}')
    return vnum


if __name__ == '__main__':
    main()
