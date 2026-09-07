#!/usr/bin/env python3
"""Add an 'MC Service Delivery' sheet to kpi-tracking-analysis-dev demonstrating the
MC-01 fix: MC Hours KPI = SUM(clockify_hours) over the per-customer-per-week rows of
vw_mc_ticket_activity. The OLD bug used MAX, which showed only the single largest
customer's hours (understated total). DEV 604775478093 only.
"""
import boto3
ACCT='604775478093'; REGION='us-east-1'
ANALYSIS_ID='kpi-tracking-analysis-dev'
SHEET_ID='sheet-kpi-mc'
DS_ID='mc_ticket_activity'
DS_ARN=f'arn:aws:quicksight:us-east-1:{ACCT}:dataset/mc-ticket-activity'

qs=boto3.client('quicksight', region_name=REGION)
assert boto3.client('sts').get_caller_identity()['Account']==ACCT,'WRONG ACCOUNT'
resp=qs.describe_analysis_definition(AwsAccountId=ACCT, AnalysisId=ANALYSIS_ID)
defn=resp['Definition']
name=qs.describe_analysis(AwsAccountId=ACCT, AnalysisId=ANALYSIS_ID)['Analysis']['Name']

ids=defn.setdefault('DataSetIdentifierDeclarations',[])
if not any(d['Identifier']==DS_ID for d in ids):
    ids.append({'Identifier':DS_ID,'DataSetArn':DS_ARN})

def kpi(vid,title,col,agg):
    return {'KPIVisual':{'VisualId':vid,
        'Title':{'Visibility':'VISIBLE','FormatText':{'PlainText':title}},
        'Subtitle':{'Visibility':'VISIBLE'},
        'ChartConfiguration':{'FieldWells':{'Values':[{'NumericalMeasureField':{
            'FieldId':vid+'-f','Column':{'DataSetIdentifier':DS_ID,'ColumnName':col},
            'AggregationFunction':{'SimpleNumericalAggregation':agg}}}],'TargetValues':[],'TrendGroups':[]},
            'SortConfiguration':{},
            'KPIOptions':{'PrimaryValueDisplayType':'ACTUAL','Sparkline':{'Visibility':'HIDDEN','Type':'LINE'},
                'VisualLayoutOptions':{'StandardLayout':{'Type':'VERTICAL'}}}},
        'Actions':[],'ColumnHierarchies':[]}}

def table(vid,title):
    vals=[('clockify_hours','SUM'),('billable_hours','SUM'),('total_issues','SUM'),('open_escalations','SUM')]
    return {'TableVisual':{'VisualId':vid,
        'Title':{'Visibility':'VISIBLE','FormatText':{'PlainText':title}},
        'Subtitle':{'Visibility':'VISIBLE'},
        'ChartConfiguration':{'FieldWells':{'TableAggregatedFieldWells':{
            'GroupBy':[{'CategoricalDimensionField':{'FieldId':vid+'-cust','Column':{'DataSetIdentifier':DS_ID,'ColumnName':'customer_name'}}}],
            'Values':[{'NumericalMeasureField':{'FieldId':vid+'-'+c,'Column':{'DataSetIdentifier':DS_ID,'ColumnName':c},'AggregationFunction':{'SimpleNumericalAggregation':a}}} for c,a in vals]}}},
        'Actions':[]}}

visuals=[
    kpi('mc-hours','Total MC Hours','clockify_hours','SUM'),        # MC-01 fix (was MAX)
    kpi('mc-billable','Total MC Billable Hours','billable_hours','SUM'),
    kpi('mc-issues','Total MC Issues','total_issues','SUM'),
    table('mc-tbl','MC Activity by Customer'),
]
layout={'Configuration':{'GridLayout':{'Elements':[
    {'ElementId':'mc-hours','ElementType':'VISUAL','ColumnIndex':0,'ColumnSpan':6,'RowIndex':0,'RowSpan':6},
    {'ElementId':'mc-billable','ElementType':'VISUAL','ColumnIndex':6,'ColumnSpan':6,'RowIndex':0,'RowSpan':6},
    {'ElementId':'mc-issues','ElementType':'VISUAL','ColumnIndex':12,'ColumnSpan':6,'RowIndex':0,'RowSpan':6},
    {'ElementId':'mc-tbl','ElementType':'VISUAL','ColumnIndex':0,'ColumnSpan':18,'RowIndex':6,'RowSpan':10},
]}}}
new_sheet={'SheetId':SHEET_ID,'Name':'MC Service Delivery','Visuals':visuals,'Layouts':[layout]}
sheets=[s for s in defn.get('Sheets',[]) if s.get('SheetId')!=SHEET_ID]
sheets.append(new_sheet)
defn['Sheets']=sheets
print('sheets now:',[s['SheetId'] for s in sheets])
out=qs.update_analysis(AwsAccountId=ACCT, AnalysisId=ANALYSIS_ID, Name=name,
    ThemeArn=resp.get('ThemeArn','arn:aws:quicksight::aws:theme/CLASSIC'), Definition=defn)
print('update status:',out.get('Status'))
