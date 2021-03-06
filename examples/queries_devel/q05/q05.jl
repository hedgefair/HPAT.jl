using HPAT
using HPAT.API.LinearRegression
HPAT.CaptureAPI.set_debug_level(3)
HPAT.DomainPass.set_debug_level(3)
HPAT.DataTablePass.set_debug_level(3)
using CompilerTools
#CompilerTools.OptFramework.set_debug_level(3)

using ParallelAccelerator
ParallelAccelerator.CGen.setCreateMain(true)
ParallelAccelerator.DomainIR.set_debug_level(3)

@acc hpat function q05(category, education, gender, file_name)
    web_clickstreams = DataSource(DataTable{:wcs_item_sk=Int64, :wcs_user_sk=Int64}, HDF5, file_name)
    item = DataSource(DataTable{:i_item_sk=Int64,:i_category_id=Int64,:i_category=Int64}, HDF5, file_name)
    customer = DataSource(DataTable{:c_customer_sk=Int64,:c_current_cdemo_sk=Int64}, HDF5, file_name)
    customer_demographics = DataSource(DataTable{:cd_demo_sk=Int64,:cd_gender=Int64,:cd_education_status=Int64}, HDF5, file_name)
    # TODO: following two filters are added by spark as an optimization;
    # I am adding manually. Need to add optimization in datatable pass
    web_clickstreams = web_clickstreams[:wcs_user_sk<typemax(Int32)]
    customer = customer[:c_current_cdemo_sk<typemax(Int32)]
    # typemax(Int32) used for NULL; typemin(Int32) was not working
    web_clickstreams = web_clickstreams[:wcs_item_sk<typemax(Int32)]

    user_items = join(web_clickstreams, item, :wcs_item_sk==:i_item_sk, :user_items_sk)

    user_clicks_in_cat = aggregate(user_items, :wcs_user_sk, :clicks_in_category = sum(:i_category==category),
                                                         :clicks_in_1 = sum(:i_category_id==1),
                                                         :clicks_in_2 = sum(:i_category_id==2),
                                                         :clicks_in_3 = sum(:i_category_id==3),
                                                         :clicks_in_4 = sum(:i_category_id==4),
                                                         :clicks_in_5 = sum(:i_category_id==5),
                                                         :clicks_in_6 = sum(:i_category_id==6),
                                                         :clicks_in_7 = sum(:i_category_id==7))
    customer_clicks = join(user_clicks_in_cat, customer, :wcs_user_sk==:c_customer_sk, :customer_clicks_sk)
    customer_demo_clicks = join(customer_clicks, customer_demographics, :c_current_cdemo_sk==:cd_demo_sk , :customer_demo_clicks_sk)
    # To make int array from bool
    college_education = 1.*(customer_demo_clicks[:cd_education_status].==education)
    male = 1.*(customer_demo_clicks[:cd_gender].==gender)
    responses = 1.0 .*(customer_demo_clicks[:clicks_in_category])
    data = transpose(hcat(college_education,
            male,
            customer_demo_clicks[:clicks_in_1],
            customer_demo_clicks[:clicks_in_2],
            customer_demo_clicks[:clicks_in_3],
            customer_demo_clicks[:clicks_in_4],
            customer_demo_clicks[:clicks_in_5],
            customer_demo_clicks[:clicks_in_6],
            customer_demo_clicks[:clicks_in_7]))
    pointsF = convert(Matrix{Float64},data)
    model = LinearRegression(pointsF, responses)
    return customer_demo_clicks[:customer_demo_clicks_sk], customer_demo_clicks[:cd_gender]
end

println(q05(3, 8303423, 1, "test_q05.hdf5"))
