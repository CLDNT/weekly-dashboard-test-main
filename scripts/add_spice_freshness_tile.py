#!/usr/bin/env python3
"""Add a 'Data Freshness' sheet (SPICE refresh health) to kpi-tracking-analysis-dev.

Idempotent: if the sheet already exists it is replaced. Backs up nothing itself
(caller already backed up the definition). DEV account 604775478093 only.
"""
import json, boto3, sys

ACCT = '604775478093'
ANALYSIS_ID = 'kpi-tracking-analysis-dev'
REGION = 'us-east-1'
DS_ID = 'spice_freshness'
DS_ARN = f'arn:aws:quicksight:us-east-1:{ACCT}:dataset/spice-freshness'
SHEET_ID = 'sheet-kpi-freshness'

qs = boto3.client('quicksight', region_name=REGION)

resp = qs.describe_analysis_definition(AwsAccountId=ACCT, AnalysisId=ANALYSIS_ID)
defn = resp['Definition']
name = qs.describe_analysis(AwsAccountId=ACCT, AnalysisId=ANALYSIS_ID)['Analysis']['Name']

# guard: account check
who = boto3.client('sts').get_caller_identity()['Account']
assert who == ACCT, f'WRONG ACCOUNT {who}'

# 1. Ensure dataset identifier declaration
ids = defn.setdefault('DataSetIdentifierDeclarations', [])
if not any(d['Identifier'] == DS_ID for d in ids):
    ids.append({'Identifier': DS_ID, 'DataSetArn': DS_ARN})
    print(f'Added dataset identifier {DS_ID}')

def kpi_visual(vid, title, ds_id, col, agg='MAX'):
    return {'KPIVisual': {
        'VisualId': vid,
        'Title': {'Visibility': 'VISIBLE', 'FormatText': {'PlainText': title}},
        'Subtitle': {'Visibility': 'VISIBLE'},
        'ChartConfiguration': {
            'FieldWells': {'Values': [{'NumericalMeasureField': {
                'FieldId': vid + '-f',
                'Column': {'DataSetIdentifier': ds_id, 'ColumnName': col},
                'AggregationFunction': {'SimpleNumericalAggregation': agg}}}],
                'TargetValues': [], 'TrendGroups': []},
            'SortConfiguration': {},
            'KPIOptions': {'PrimaryValueDisplayType': 'ACTUAL',
                           'Sparkline': {'Visibility': 'HIDDEN', 'Type': 'LINE'},
                           'VisualLayoutOptions': {'StandardLayout': {'Type': 'VERTICAL'}}}},
        'Actions': [], 'ColumnHierarchies': []}}

def table_visual(vid, title, ds_id, col):
    return {'TableVisual': {
        'VisualId': vid,
        'Title': {'Visibility': 'VISIBLE', 'FormatText': {'PlainText': title}},
        'Subtitle': {'Visibility': 'VISIBLE'},
        'ChartConfiguration': {'FieldWells': {'TableUnaggregatedFieldWells': {'Values': [
            {'FieldId': vid + '-f',
             'Column': {'DataSetIdentifier': ds_id, 'ColumnName': col}}]}}},
        'Actions': []}}

# 2. Build the sheet
visuals = [
    kpi_visual('fresh-ok', 'SPICE Datasets OK', DS_ID, 'datasets_ok'),
    kpi_visual('fresh-tracked', 'Datasets Tracked', DS_ID, 'datasets_tracked'),
    kpi_visual('fresh-failed', 'Datasets Failed', DS_ID, 'datasets_failed'),
    table_visual('fresh-asof', 'Data as of (last successful SPICE refresh)', DS_ID, 'last_successful_display'),
]

layout = {'Configuration': {'GridLayout': {'Elements': [
    {'ElementId': 'fresh-ok',      'ElementType': 'VISUAL', 'ColumnIndex': 0, 'ColumnSpan': 6, 'RowIndex': 0, 'RowSpan': 6},
    {'ElementId': 'fresh-tracked', 'ElementType': 'VISUAL', 'ColumnIndex': 6, 'ColumnSpan': 6, 'RowIndex': 0, 'RowSpan': 6},
    {'ElementId': 'fresh-failed',  'ElementType': 'VISUAL', 'ColumnIndex': 12,'ColumnSpan': 6, 'RowIndex': 0, 'RowSpan': 6},
    {'ElementId': 'fresh-asof',    'ElementType': 'VISUAL', 'ColumnIndex': 0, 'ColumnSpan': 18,'RowIndex': 6, 'RowSpan': 6},
]}}}

new_sheet = {'SheetId': SHEET_ID, 'Name': 'Data Freshness', 'Visuals': visuals, 'Layouts': [layout]}

sheets = defn.setdefault('Sheets', [])
sheets = [s for s in sheets if s.get('SheetId') != SHEET_ID]
sheets.append(new_sheet)
defn['Sheets'] = sheets
print(f'Sheets now: {[s["SheetId"] for s in sheets]}')

# 3. Update analysis
kwargs = dict(AwsAccountId=ACCT, AnalysisId=ANALYSIS_ID, Name=name, Definition=defn)
theme = resp.get('ThemeArn') or 'arn:aws:quicksight::aws:theme/CLASSIC'
kwargs['ThemeArn'] = theme
out = qs.update_analysis(**kwargs)
print('update_analysis status:', out.get('Status'), out.get('AnalysisId'))
