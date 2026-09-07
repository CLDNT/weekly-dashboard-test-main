#!/usr/bin/env python3
"""Add an 'Escalations' sheet to kpi-tracking-analysis-dev demonstrating the
ESC-01/02 fixes:
  - ESC-01 'High Priority': SUM(high_priority_count) — the view already filters to
    priority High/Highest; the OLD bug counted ALL open escalations.
  - ESC-02 'Avg Days Open': AVERAGE(avg_days_open) — the OLD bug used MAX.
Also a Total Open tile and a by-customer detail table. DEV 604775478093 only.
"""
import boto3

ACCT='604775478093'; REGION='us-east-1'
ANALYSIS_ID='kpi-tracking-analysis-dev'
SHEET_ID='sheet-kpi-escalations'
DS_ID='esc_by_customer'
DS_ARN=f'arn:aws:quicksight:us-east-1:{ACCT}:dataset/escalations-by-customer'

qs=boto3.client('quicksight', region_name=REGION)
assert boto3.client('sts').get_caller_identity()['Account']==ACCT, 'WRONG ACCOUNT'

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
            'KPIOptions':{'PrimaryValueDisplayType':'ACTUAL',
                'Sparkline':{'Visibility':'HIDDEN','Type':'LINE'},
                'VisualLayoutOptions':{'StandardLayout':{'Type':'VERTICAL'}}}},
        'Actions':[],'ColumnHierarchies':[]}}

def table(vid,title,cols):
    def grp(c): return {'CategoricalDimensionField':{'FieldId':vid+'-'+c,'Column':{'DataSetIdentifier':DS_ID,'ColumnName':c}}} if c=='customer_name' else None
    vals=[]
    for c,agg in cols:
        if c=='customer_name':
            continue
        vals.append({'NumericalMeasureField':{'FieldId':vid+'-'+c,'Column':{'DataSetIdentifier':DS_ID,'ColumnName':c},'AggregationFunction':{'SimpleNumericalAggregation':agg}}})
    return {'TableVisual':{'VisualId':vid,
        'Title':{'Visibility':'VISIBLE','FormatText':{'PlainText':title}},
        'Subtitle':{'Visibility':'VISIBLE'},
        'ChartConfiguration':{'FieldWells':{'TableAggregatedFieldWells':{
            'GroupBy':[{'CategoricalDimensionField':{'FieldId':vid+'-customer_name','Column':{'DataSetIdentifier':DS_ID,'ColumnName':'customer_name'}}}],
            'Values':vals}}},
        'Actions':[]}}

visuals=[
    kpi('esc-open','Total Open Escalations','open_escalations','SUM'),
    kpi('esc-high','High Priority (High/Highest)','high_priority_count','SUM'),   # ESC-01 fix
    kpi('esc-avgdays','Avg Days Open','avg_days_open','AVERAGE'),                 # ESC-02 fix
    table('esc-tbl','Escalations by Customer',[
        ('customer_name',None),('open_escalations','SUM'),('high_priority_count','SUM'),
        ('avg_days_open','AVERAGE'),('avg_days_to_resolve','AVERAGE')]),
]
layout={'Configuration':{'GridLayout':{'Elements':[
    {'ElementId':'esc-open','ElementType':'VISUAL','ColumnIndex':0,'ColumnSpan':6,'RowIndex':0,'RowSpan':6},
    {'ElementId':'esc-high','ElementType':'VISUAL','ColumnIndex':6,'ColumnSpan':6,'RowIndex':0,'RowSpan':6},
    {'ElementId':'esc-avgdays','ElementType':'VISUAL','ColumnIndex':12,'ColumnSpan':6,'RowIndex':0,'RowSpan':6},
    {'ElementId':'esc-tbl','ElementType':'VISUAL','ColumnIndex':0,'ColumnSpan':18,'RowIndex':6,'RowSpan':10},
]}}}
new_sheet={'SheetId':SHEET_ID,'Name':'Escalations','Visuals':visuals,'Layouts':[layout]}
sheets=[s for s in defn.get('Sheets',[]) if s.get('SheetId')!=SHEET_ID]
sheets.append(new_sheet)
defn['Sheets']=sheets
print('sheets now:',[s['SheetId'] for s in sheets])
out=qs.update_analysis(AwsAccountId=ACCT, AnalysisId=ANALYSIS_ID, Name=name,
    ThemeArn=resp.get('ThemeArn','arn:aws:quicksight::aws:theme/CLASSIC'), Definition=defn)
print('update status:',out.get('Status'))
