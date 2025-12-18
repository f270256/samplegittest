/****** Object:  StoredProcedure [dbo].[pcr_sp_fin_calculate_discounts]    Script Date: 12/16/2025 10:16:29 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

ALTER procedure [dbo].[pcr_sp_fin_calculate_discounts]
(
	@householdId int,
	@additionalDeposit bit = null,
	@payInFull bit = null
)
as
begin
	declare @householdIdLocal int = @householdId
	declare @additionalDepositLocal bit = @additionalDeposit
	declare @payInFullLocal bit = @payInFull

	if (@additionalDepositLocal is null) set @additionalDepositLocal = 0
	if (@payInFullLocal is null) set @payInFullLocal = 0

	if OBJECT_ID('tempdb..#productStudents') is null
	begin
		raiserror('Procedure expects temp table #productStudents (productId, studentId).', 16, 1)
		return
	end
	if OBJECT_ID('tempdb..#waiverCodes') is null
	begin
		raiserror('Procedure expects temp table #waiverCodes (code).', 16, 1)
		return
	end

	/****************************************************************************
					Discount Calculations
	 ****************************************************************************/

	declare @total decimal(18, 6)
	declare @now datetime = dbo.pcr_fx_gettime()

	-- Sales price to discount
	select @total = sum(product_sale_price)
	from [dbo].[fin_products], #productStudents ps
	where ps.productId = fin_products.product_id

	declare @totals table (total decimal(18, 6), eligible_for_entity_id int, eligible_for_entity_type varchar(20) )
	insert into @totals (total, eligible_for_entity_id, eligible_for_entity_type)
	select sum(product_sale_price), ps.studentId, 'student'
	from [dbo].[fin_products], #productStudents ps
	where ps.productId = fin_products.product_id
	group by ps.studentId
	union all
	select @total, @householdIdLocal, 'Household'
	union all
	select @total, 0, null

	declare @eligibleProducts table (
		id int identity(1, 1),
		product_id int, 
		account_id int,
		eligible_for_entity_id int,
		eligible_for_entity_type varchar(20), 
		count_of_product_discounts int,
		waiver_code varchar(50),
		product_path int,
		discount_order int,
		fixed_amount decimal(18,6),
		percent_amount decimal(18,4),
		total_percent_amount decimal(18,4),
		actual_amount decimal(18,6)
	)

	declare @eligibleProductProducts table (
		id int identity(1,1),
		discount_product_id int,
		purchase_product_id int,
		eligible_for_entity_id int,
		eligible_for_entity_type varchar(20),
		waiver_code varchar(50),
		tmp_amount decimal(18,6),
		student_id int,
		product_student_id int
	)

	-- Discount Eligibility

	-- Discount without waivecode
	insert into @eligibleProducts
	(product_id, account_id, eligible_for_entity_id, eligible_for_entity_type, count_of_product_discounts)
	select fin_products.product_id, fin_products.default_revenue_account_id,
		case when fin_products.restriction_type = 'PerCamper' then ps.studentId 
			when fin_products.restriction_type = 'PerFamily' then @householdIdLocal
			else 0 end eligible_for_id, 
		case when fin_products.restriction_type = 'PerCamper' then 'Student'
			when fin_products.restriction_type = 'PerFamily' then 'Household'
			else null end eligible_for,
		count(*) total
	from fin_products, [dbo].[fin_discounts_eligible_products] e, #productStudents ps
	where eligible_product_id = ps.productId
	and fin_products.product_id = e.product_id
	and fin_products.discount_min_product_count  > 0
	and fin_products.is_waiver = 0
	and fin_products.is_product_active = 1
	and fin_products.product_type = 'Discount'
	and coalesce(fin_products.expiration_date, @now) >= @now
	and (coalesce(fin_products.pay_in_full_discount, 0) = 0 or fin_products.pay_in_full_discount = @payInFullLocal)
	and exists (
		-- Student has eligible attribute
		select 1
		from fin_discount_eligible_attributes dea, student_descriptors
		where dea.attribute_id = student_descriptors.descriptor_type_id
		and dea.product_id = fin_products.product_id
		and student_descriptors.student_id = ps.studentId
		union 
		-- Attributes not applicable for discount
		select 1
		where not exists (
			select *
			from fin_discount_eligible_attributes dea
			where dea.product_id = fin_products.product_id
		)
	)
	group by fin_products.product_id, fin_products.Product_Sale_Price, fin_products.discount_min_product_count, 
		fin_products.restriction_type, fin_products.default_revenue_account_id,
		case when fin_products.restriction_type = 'PerCamper' then ps.studentId 
			when fin_products.restriction_type = 'PerFamily' then @householdIdLocal
			else 0 end
	having count(*) >= fin_products.discount_min_product_count 

	insert into @eligibleProductProducts
	(discount_product_id, purchase_product_id, eligible_for_entity_id, eligible_for_entity_type, student_id, product_student_id)
	select discount_product_id, purchase_product_id, eligible_for_id, eligible_for, studentId, product_student_id
	from (
		select fin_products.product_id as discount_product_id, ps.productId as purchase_product_id,
			case when fin_products.restriction_type = 'PerCamper' then ps.studentId 
				when fin_products.restriction_type = 'PerFamily' then @householdIdLocal
				else 0 end eligible_for_id, 
			case when fin_products.restriction_type = 'PerCamper' then 'Student'
				when fin_products.restriction_type = 'PerFamily' then 'Household'
				else null end eligible_for,
			ps.studentId, ps.id as product_student_id
		from fin_products, [dbo].[fin_discounts_eligible_products] e, #productStudents ps
		where eligible_product_id = ps.productId
		and fin_products.product_id = e.product_id
		and fin_products.discount_min_product_count  > 0
		and fin_products.is_waiver = 0
		and fin_products.is_product_active = 1
		and fin_products.product_type = 'Discount'
		and coalesce(fin_products.expiration_date, @now) >= @now
		and exists (
			-- Student has eligible attribute
			select 1
			from fin_discount_eligible_attributes dea, student_descriptors
			where dea.attribute_id = student_descriptors.descriptor_type_id
			and dea.product_id = fin_products.product_id
			and student_descriptors.student_id = ps.studentId
			union 
			-- Attributes not applicable for discount
			select 1
			where not exists (
				select *
				from fin_discount_eligible_attributes dea
				where dea.product_id = fin_products.product_id
			)
		)
	) d
	where  exists (
		select *
		from @eligibleProducts ep
		where ep.product_id = d.discount_product_id
		and ep.eligible_for_entity_id = d.eligible_for_id
		and coalesce(ep.eligible_for_entity_type, 'xxx') = coalesce(d.eligible_for, 'xxx')
	)

	-- Discount with waivecode
	insert into @eligibleProducts
	(product_id, account_id, eligible_for_entity_id, eligible_for_entity_type, count_of_product_discounts, waiver_code)
	select fin_products.product_id, fin_products.default_revenue_account_id,
		case when fin_products.restriction_type = 'PerCamper' then ps.studentId 
			when fin_products.restriction_type = 'PerFamily' then @householdIdLocal
			else 0 end eligible_for_id, 
		case when fin_products.restriction_type = 'PerCamper' then 'Student'
			when fin_products.restriction_type = 'PerFamily' then 'Household'
			else null end eligible_for,
		count(*) total,
		fin_product_waiver_codes.waiver_code
	from fin_products, [dbo].[fin_discounts_eligible_products] e, #productStudents ps, fin_product_waiver_codes, #waiverCodes waivers
	where eligible_product_id = ps.productId
	and fin_products.product_id = e.product_id
	and ps.productId = e.eligible_product_id
	and fin_product_waiver_codes.product_id = fin_products.product_id
	and fin_products.discount_min_product_count  > 0
	and fin_product_waiver_codes.waiver_code = waivers.code
	and waivers.code <> ''
	and fin_products.is_waiver = 1
	and fin_products.is_product_active = 1
	and fin_products.product_type = 'Discount'
	and fin_product_waiver_codes.is_issued = 1
	and fin_product_waiver_codes.is_applied = 0
	and coalesce(fin_products.expiration_date, @now) >= @now
	and (coalesce(fin_products.pay_in_full_discount, 0) = 0 or fin_products.pay_in_full_discount = @payInFullLocal)
	and exists (
		-- Student has eligible attribute
		select 1
		from fin_discount_eligible_attributes dea, student_descriptors
		where dea.attribute_id = student_descriptors.descriptor_type_id
		and dea.product_id = fin_products.product_id
		and student_descriptors.student_id = ps.studentId
		union 
		-- Attributes not applicable for discount
		select 1
		where not exists (
			select *
			from fin_discount_eligible_attributes dea
			where dea.product_id = fin_products.product_id
		)
	)
	group by fin_products.product_id, fin_products.Product_Sale_Price, fin_products.discount_min_product_count, 
		fin_products.restriction_type, fin_product_waiver_codes.waiver_code,
		fin_products.default_revenue_account_id,
		case when fin_products.restriction_type = 'PerCamper' then ps.studentId 
			when fin_products.restriction_type = 'PerFamily' then @householdIdLocal
			else 0 end
	having count(*) >= fin_products.discount_min_product_count 

	insert into @eligibleProductProducts
	(discount_product_id, purchase_product_id, eligible_for_entity_id, eligible_for_entity_type, waiver_code, student_id, product_student_id)
	select discount_product_id, purchase_product_id, eligible_for_id, eligible_for, code, studentid, product_student_id
	from (
		select fin_products.product_id as discount_product_id, ps.productId as purchase_product_id,
			case when fin_products.restriction_type = 'PerCamper' then ps.studentId 
				when fin_products.restriction_type = 'PerFamily' then @householdIdLocal
				else 0 end eligible_for_id, 
			case when fin_products.restriction_type = 'PerCamper' then 'Student'
				when fin_products.restriction_type = 'PerFamily' then 'Household'
				else null end eligible_for,
			waivers.code,
			ps.studentid, ps.id as product_student_id
		from fin_products, [dbo].[fin_discounts_eligible_products] e, #productStudents ps, fin_product_waiver_codes, #waiverCodes waivers
		where eligible_product_id = ps.productId
		and fin_products.product_id = e.product_id
		and ps.productId = e.eligible_product_id
		and fin_product_waiver_codes.product_id = fin_products.product_id
		and fin_products.discount_min_product_count  > 0
		and fin_product_waiver_codes.waiver_code = waivers.code
		and waivers.code <> ''
		and fin_products.is_waiver = 1
		and fin_products.is_product_active = 1
		and fin_products.product_type = 'Discount'
		and fin_product_waiver_codes.is_issued = 1
		and fin_product_waiver_codes.is_applied = 0
		and coalesce(fin_products.expiration_date, @now) >= @now
		and exists (
			-- Student has eligible attribute
			select 1
			from fin_discount_eligible_attributes dea, student_descriptors
			where dea.attribute_id = student_descriptors.descriptor_type_id
			and dea.product_id = fin_products.product_id
			and student_descriptors.student_id = ps.studentId
			union 
			-- Attributes not applicable for discount
			select 1
			where not exists (
				select *
				from fin_discount_eligible_attributes dea
				where dea.product_id = fin_products.product_id
			)
		)
	) d
	where  exists (
		select *
		from @eligibleProducts ep
		where ep.product_id = d.discount_product_id
		and ep.eligible_for_entity_id = d.eligible_for_id
		and coalesce(ep.eligible_for_entity_type, 'xxx') = coalesce(d.eligible_for, 'xxx')
	)


	-- Product Discounts that can appear only once per day should be removed as options.
	DELETE FROM @eligibleProducts
	WHERE id IN (
		SELECT id
		FROM @eligibleProducts ds
		WHERE EXISTS ( 
			SELECT fin_products.product_id
			FROM fin_customer_invoices
			INNER JOIN fin_customer_invoice_items ON
				(fin_customer_invoices.customer_invoice_id = fin_customer_invoice_items.customer_invoice_id)
			INNER JOIN fin_products ON
				(fin_products.product_id = fin_customer_invoice_items.product_id
				AND fin_products.discount_once_per_day = 1)
			WHERE fin_customer_invoices.issued_date = CONVERT(DATE, @now)
			AND fin_customer_invoices.voided_id IS NULL
			AND ds.eligible_for_entity_id = fin_customer_invoices.person_id
			AND ds.eligible_for_entity_type = fin_customer_invoices.person_type
			AND ds.product_id = fin_customer_invoice_items.product_id
			UNION 
			SELECT fin_products.product_id
			FROM fin_customer_invoices
			INNER JOIN fin_customer_invoice_items ON
				(fin_customer_invoices.customer_invoice_id = fin_customer_invoice_items.customer_invoice_id)
			INNER JOIN fin_products ON
				(fin_products.product_id = fin_customer_invoice_items.product_id
				AND fin_products.discount_once_per_day = 1)
			WHERE fin_customer_invoices.issued_date = CONVERT(DATE, @now)
			AND fin_customer_invoices.voided_id IS NULL
			AND (ds.eligible_for_entity_id = @householdIdLocal OR ds.eligible_for_entity_id = 0)
			AND (ds.eligible_for_entity_type = 'Household' OR ds.eligible_for_entity_type IS NULL)
			AND ds.product_id = fin_customer_invoice_items.product_id
			AND fin_customer_invoices.customer_id = @householdIdLocal
		)
	)

	IF EXISTS (
		SELECT *
		FROM  @eligibleProducts ep
		INNER JOIN fin_products p ON
			(ep.product_id = p.product_id)
		WHERE p.percent_or_fixed = 'fixedpersession'
	)
	AND EXISTS (
		SELECT *
		FROM  @eligibleProducts ep
		INNER JOIN fin_products p ON
			(ep.product_id = p.product_id)
		WHERE p.percent_or_fixed = 'totalpercent'
	)
		DELETE FROM @eligibleProducts WHERE id IN (
			SELECT id FROM
			(
				SELECT ep.id, ROW_NUMBER() OVER (PARTITION BY p.product_id ORDER BY p.discount_order, ep.eligible_for_entity_id, ep.eligible_for_entity_type, ep.count_of_product_discounts) AS number
				FROM  @eligibleProducts ep
				INNER JOIN fin_products p ON
					(ep.product_id = p.product_id)
				WHERE p.percent_or_fixed in ('fixedpersession', 'totalpercent')
			)t
			WHERE number > 1
		)
	

	-- Product that can appear only once per session should be removed as options.
	DELETE FROM @eligibleProductProducts
	WHERE id IN (
			select id from (
			SELECT epp.id, ROW_NUMBER() over (PARTITION BY p2.product_id, epp.eligible_for_entity_id, eligible_for_entity_type order by (select 1)) as number,
			case when p2.discount_min_product_count > 0 then p2.discount_min_product_count else 1 end as min_number
			FROM  @eligibleProductProducts epp
			inner join fin_products p1 on
				(epp.purchase_product_id = p1.product_id)
			inner join fin_products p2 on
				(epp.discount_product_id = p2.product_id)
			WHERE p2.percent_or_fixed = 'fixedpersession')t
			where number > min_number)

	-- All eligible discounts codes
	-- Calculate best discount by stackability and order
	-- case when percent_or_fixed = 'Percent' then 
	update @eligibleProducts
	set product_path = case when fin_products.is_stackable = 1 then 0 else ep.id end,
		discount_order = fin_products.discount_order,
		fixed_amount = case when percent_or_fixed = 'fixed' then product_sale_price
			-- Evenly split discount between product if fixedpersession and discount_once_per_day is not set
			when percent_or_fixed = 'fixedpersession' then product_sale_price / (case when discount_min_product_count > 0 then discount_min_product_count else 1.0 end)
			else 0.0 end,
		percent_amount = case when percent_or_fixed = 'Percent' then product_sale_price else 0.0 end,
		total_percent_amount = case when percent_or_fixed = 'TotalPercent' then product_sale_price else 0.0 end,
		actual_amount = case when percent_or_fixed = 'Exact' then product_sale_price else NULL end
	from @eligibleProducts ep, fin_products
	where ep.product_id = fin_products.product_id

	
	-- Include per camp stacklable discounts as an option with id as product_path
	insert into @eligibleProducts
	(product_id, account_id, eligible_for_entity_id, eligible_for_entity_type, count_of_product_discounts, waiver_code, product_path, discount_order, fixed_amount, percent_amount, actual_amount, total_percent_amount)
	select ep.product_id, account_id, eligible_for_entity_id, eligible_for_entity_type, count_of_product_discounts, waiver_code, ep.id, ep.discount_order, fixed_amount, percent_amount, actual_amount, total_percent_amount
	from @eligibleProducts ep, fin_products
	where ep.product_id = fin_products.product_id
	and eligible_for_entity_type = 'student'
	and fin_products.is_stackable = 1


	-- Evenly split discount between students.  Maybe should be prorated.
	update @eligibleProducts
	set fixed_amount = fixed_amount / (select count(distinct studentid) from #productStudents)
	from @eligibleProducts
	where waiver_code <> ''
	and fixed_amount <> 0.0
	and eligible_for_entity_type = 'Household'

	declare @pathResults table (
		path_num int,
		cur_total decimal(18,6),
		cur_total_tmp decimal(18,6)
	)

	insert into @pathResults
	(path_num, cur_total, cur_total_tmp)
	select distinct product_path, @total, @total
	from @eligibleProducts ep

	declare @discountsApplied table (
		id int identity(1,1),
		product_path int, 
		discount_order int,
		discount_product_id int, 
		originating_product_id int,
		product_student_id int,
		eligible_for_entity_id int, 
		eligible_for_entity_type varchar(20), 
		student_id int,
		waiver_code varchar(50),
		account_id int,
		amount decimal(18,6)
	)


	update @eligibleProducts
	set discount_order = new_order
	from @eligibleProducts ep, (
		select id,
			row_number() over (order by discount_order, id) new_order
		from @eligibleProducts
	) d
	where ep.id = d.id

	declare @maxOrder int
	select @maxOrder = max(discount_order) 
	from @eligibleProducts


	declare @i int = 1
	if (@maxOrder >= 1)
		while (@i <= @maxOrder and @i < 1000)
		begin

			-- Distribute Pick 3 fixed amount type logic:
			-- Distribute absolute amount proportionally over all selected pick 3 items.  
			-- Store result in temp amount which will be used instead of the fixed_amount
			if exists (
				select count(*)
				from @eligibleProducts ep
				inner join @eligibleProductProducts epp on (
					epp.discount_product_id = ep.product_id
					and coalesce(epp.eligible_for_entity_type, 'xxx') = coalesce(ep.eligible_for_entity_type, 'xxx')
					and epp.eligible_for_entity_id = ep.eligible_for_entity_id
					and coalesce(ep.waiver_code, 'ZZZZZZZZZZZZZZZZZZZZZZZZ') = coalesce(epp.waiver_code, 'ZZZZZZZZZZZZZZZZZZZZZZZZ')
				)
				inner join fin_products dp on
					(epp.discount_product_id = dp.product_id)
				where ep.fixed_amount <> 0.0
				and ep.account_id is null
				and dp.percent_or_fixed <> 'fixedpersession'
				having count(*) > 1
			)
			begin

				declare @itemCount int, 
					@itemTotal decimal(18,6),
					@remainder decimal(18,6),
					@remainderId int

				select @itemCount = count(*), @itemTotal = sum(fin_products.product_sale_price)
				from @eligibleProducts ep
				inner join @eligibleProductProducts epp on (
					epp.discount_product_id = ep.product_id
					and coalesce(epp.eligible_for_entity_type, 'xxx') = coalesce(ep.eligible_for_entity_type, 'xxx')
					and epp.eligible_for_entity_id = ep.eligible_for_entity_id
					and coalesce(ep.waiver_code, 'ZZZZZZZZZZZZZZZZZZZZZZZZ') = coalesce(epp.waiver_code, 'ZZZZZZZZZZZZZZZZZZZZZZZZ')
				)
				inner join fin_products dp on
					(epp.discount_product_id = dp.product_id)
				inner join fin_products on
					(epp.purchase_product_id = fin_products.product_id)
				where ep.discount_order = @i 
				and dp.percent_or_fixed <> 'fixedpersession'

				update @eligibleProductProducts
				set tmp_amount = ep.fixed_amount * fin_products.product_sale_price / @itemTotal
				from @eligibleProducts ep
				inner join @eligibleProductProducts epp on (
					epp.discount_product_id = ep.product_id
					and coalesce(epp.eligible_for_entity_type, 'xxx') = coalesce(ep.eligible_for_entity_type, 'xxx')
					and epp.eligible_for_entity_id = ep.eligible_for_entity_id
					and coalesce(ep.waiver_code, 'ZZZZZZZZZZZZZZZZZZZZZZZZ') = coalesce(epp.waiver_code, 'ZZZZZZZZZZZZZZZZZZZZZZZZ')
				)
				inner join fin_products dp on
					(epp.discount_product_id = dp.product_id)
				inner join fin_products on
					(epp.purchase_product_id = fin_products.product_id)
				where ep.discount_order = @i 
				and ep.fixed_amount <> 0.0
				and dp.percent_or_fixed <> 'fixedpersession'


				select @remainder =  ep.fixed_amount - sum(tmp_amount)
				from @eligibleProducts ep
				inner join @eligibleProductProducts epp on (
					epp.discount_product_id = ep.product_id
					and coalesce(epp.eligible_for_entity_type, 'xxx') = coalesce(ep.eligible_for_entity_type, 'xxx')
					and epp.eligible_for_entity_id = ep.eligible_for_entity_id
					and coalesce(ep.waiver_code, 'ZZZZZZZZZZZZZZZZZZZZZZZZ') = coalesce(epp.waiver_code, 'ZZZZZZZZZZZZZZZZZZZZZZZZ')
				)
				inner join fin_products dp on
					(epp.discount_product_id = dp.product_id)
				where ep.discount_order = @i 
				and ep.fixed_amount <> 0.0
				and dp.percent_or_fixed <> 'fixedpersession'
				group by ep.fixed_amount

				if (@remainder != 0.0)
				begin
					select @remainderId = max(id)
					from @eligibleProductProducts
					where abs(tmp_amount) > abs(@remainder)

					update @eligibleProductProducts
					set tmp_amount = tmp_amount + @remainder
					where id = @remainderId
				end
			end

			-- Make sure discounts applied do not exceed product sales price.  If so, change discounted amount.
			-- Account Id is null?  Use purchased product revenue account.
			insert into @discountsApplied
			(product_path, discount_order, discount_product_id, originating_product_id, product_student_id,
				eligible_for_entity_id, eligible_for_entity_type, 
				waiver_code, student_id, account_id, amount)
			-- ep.account_id is null, tmp_amount may be specified.
				select ep.product_path, @i, epp.discount_product_id, epp.purchase_product_Id, epp.product_student_id, ep.eligible_for_entity_id, ep.eligible_for_entity_type,
					ep.waiver_code, epp.student_id, coalesce(ep.account_id, fin_products.default_revenue_account_id), 
					case when ep.actual_amount is not null then ep.actual_amount - fin_products.product_sale_price
						when fin_products.product_sale_price +
							(coalesce(cur_discounted_total, 0.0) + coalesce(tmp_amount, fixed_amount) + percent_amount * fin_products.product_sale_price + total_percent_amount * coalesce(cur_total_tmp, 0.0) / ep.count_of_product_discounts) > 0
						then coalesce(tmp_amount, fixed_amount) + percent_amount * fin_products.product_sale_price + total_percent_amount * coalesce(cur_total_tmp, 0.0) / ep.count_of_product_discounts
						else - coalesce(cur_discounted_total, 0.0) - fin_products.product_sale_price
						end
			from @eligibleProducts ep
			inner join @eligibleProductProducts epp on
			  (epp.discount_product_id = ep.product_id
			   and coalesce(epp.eligible_for_entity_type, 'xxx') = coalesce(ep.eligible_for_entity_type, 'xxx')
			   and epp.eligible_for_entity_id = ep.eligible_for_entity_id
			   and coalesce(ep.waiver_code, 'ZZZZZZZZZZZZZZZZZZZZZZZZ') = coalesce(epp.waiver_code, 'ZZZZZZZZZZZZZZZZZZZZZZZZ'))
			inner join fin_products dp on
			  (dp.product_id = ep.product_id)
			inner join fin_products on
			  (epp.purchase_product_id = fin_products.product_id)
			left join (
				select product_path, sum(amount) cur_discounted_total, product_student_id
				from @discountsApplied
				group by product_path, product_student_id
			) d_discounts on
			  (d_discounts.product_path = ep.product_path and d_discounts.product_student_id = epp.product_student_id)
			left join @pathResults d_total_discounts on
			  (d_total_discounts.path_num = ep.product_path)
			where ep.discount_order = @i
			and ep.account_id is null
			and dp.percent_or_fixed <> 'fixedpersession'

			union all

			-- ep.account_id is not null.  Use discount product's account_id
			select ep.product_path, @i, ep.product_id, purchase_product_Id,  epp.product_student_id, ep.eligible_for_entity_id, ep.eligible_for_entity_type,
				ep.waiver_code, epp.student_id, ep.account_id, 
				case when ep.actual_amount is not null then ep.actual_amount - fin_products.product_sale_price
					when fin_products.product_sale_price +
						(coalesce(cur_discounted_total, 0.0) + coalesce(tmp_amount, fixed_amount) + percent_amount * fin_products.product_sale_price + total_percent_amount * coalesce(cur_total_tmp, 0.0) / ep.count_of_product_discounts) > 0
					then coalesce(tmp_amount, fixed_amount) + percent_amount * fin_products.product_sale_price + total_percent_amount * coalesce(cur_total_tmp, 0.0) / ep.count_of_product_discounts
					else - coalesce(cur_discounted_total, 0.0) - fin_products.product_sale_price
					end
			from @eligibleProducts ep			
			inner join @eligibleProductProducts epp on
			  (epp.discount_product_id = ep.product_id
			   and coalesce(epp.eligible_for_entity_type, 'xxx') = coalesce(ep.eligible_for_entity_type, 'xxx')
			   and epp.eligible_for_entity_id = ep.eligible_for_entity_id
			   and coalesce(ep.waiver_code, 'ZZZZZZZZZZZZZZZZZZZZZZZZ') = coalesce(epp.waiver_code, 'ZZZZZZZZZZZZZZZZZZZZZZZZ'))
			inner join fin_products dp on
			  (dp.product_id = ep.product_id)
			inner join fin_products on
			  (epp.purchase_product_id = fin_products.product_id)
			left join (
				select product_path, sum(amount) cur_discounted_total, product_student_id
				from @discountsApplied
				group by product_path, product_student_id
			) d_discounts on
			  (d_discounts.product_path = ep.product_path and d_discounts.product_student_id = epp.product_student_id)
			--inner join @pathResults on
			--  (path_num = ep.product_path )
			left join @pathResults d_total_discounts on
			  (d_total_discounts.path_num = ep.product_path)
			where ep.discount_order = @i
			and ep.account_id is not null
			and dp.percent_or_fixed <> 'fixedpersession'
			
						-- Once per Day discounts
			delete from @discountsApplied
			where id in (
				select id
				from (
					select da.id, row_number() over (partition by da.discount_product_id order by amount) items
					from @discountsApplied da, fin_products d
					where da.discount_order = @i
					and da.discount_product_id = d.product_id
					and discount_once_per_day = 1
					and percent_or_fixed not in ('fixedpersession', 'totalpercent')
				) d
				where d.items > 1
			)

			update @pathResults
			set cur_total_tmp = cur_total + coalesce((select sum(amount) from @discountsApplied d where d.product_path = path_num), 0.0) 

			update @eligibleProductProducts
			set tmp_amount = null
			where tmp_amount is not null


			set @i = @i + 1
		end 


	update @pathResults
	set cur_total = coalesce((select sum(case when amount < 0 then amount else 0 end) from @discountsApplied d where d.product_path = pr.path_num), 0.0)
	from @pathResults pr

	--calculate the highest discount combination and apply it
	-- For example, two stackable discounts $10 and $15 and one non-stackable $20. 
	-- Because 10+15=25 > 20, you apply first two. Otherwise, you would apply the non-stackable discount

	declare @bestPath table(path_num int)

	--case 1 apply all stackable only
	declare @stackableTotal decimal(18,6) = coalesce((select sum(cur_total) from @pathResults d where path_num = 0), 0.0)

	--case 2 apply non stackable only
	declare @nonStackableTotal decimal(18,6) = 0.0
	declare @nonStackableType varchar(20)
	select top 1 @nonStackableTotal =  coalesce(sum(cur_total), 0.0), @nonStackableType = coalesce(eligible_for_entity_type, 'xxx') 
	from (select cur_total, ROW_NUMBER() over (partition by eligible_for_entity_id,  coalesce(eligible_for_entity_type, 'xxx') order by  cur_total asc) as order_number,
	eligible_for_entity_type, discount_order from @pathResults r, @eligibleProducts rp
		where r.path_num = rp.product_path
		and path_num > 0
	)t where order_number = 1 
	group by coalesce(eligible_for_entity_type, 'xxx')
	order by sum(cur_total) asc, min(discount_order) asc


	if @nonStackableTotal > @stackableTotal
			insert into @bestPath(path_num)
				select 0
	else 
		insert into @bestPath(path_num)
			select path_num from
			(select path_num, eligible_for_entity_type, ROW_NUMBER() over (partition by eligible_for_entity_id,  coalesce(eligible_for_entity_type, 'xxx') order by cur_total asc) as order_number
			 from @pathResults r, @eligibleProducts rp
				where path_num = rp.product_path
				and path_num > 0
			)t where order_number = 1
			and coalesce(eligible_for_entity_type, 'xxx') = @nonStackableType

		-- Apply fixed-per-session discounts at the cart level after best path selection.
		declare @cartTotal decimal(18,6) = @total + coalesce((select sum(amount) from @discountsApplied d, @bestPath bp where d.product_path = bp.path_num), 0.0)

		declare @sessionDiscounts table (
			id int identity(1,1),
			product_path int,
			discount_order int,
			discount_product_id int,
			waiver_code varchar(50),
			account_id int,
			amount decimal(18,6)
		)

		insert into @sessionDiscounts (product_path, discount_order, discount_product_id, waiver_code, account_id, amount)
		select ep.product_path, ep.discount_order, ep.product_id, ep.waiver_code, coalesce(ep.account_id, fp.default_revenue_account_id), fp.product_sale_price
		from @eligibleProducts ep
		inner join fin_products fp on (ep.product_id = fp.product_id)
		inner join @bestPath bp on (bp.path_num = ep.product_path)
		where fp.percent_or_fixed = 'fixedpersession'

		declare @sMax int = (select count(*) from @sessionDiscounts)
		declare @sIdx int = 1

		while (@sIdx <= @sMax)
		begin
			declare @sPath int, @sOrder int, @sProduct int, @sWaiver varchar(50), @sAccount int, @sAmount decimal(18,6), @applyAmount decimal(18,6)
			select @sPath = product_path, @sOrder = discount_order, @sProduct = discount_product_id, @sWaiver = waiver_code,
				@sAccount = account_id, @sAmount = amount
			from (
				select *, row_number() over (order by discount_order, product_path, discount_product_id) as rn
				from @sessionDiscounts
			) s
			where rn = @sIdx

			set @applyAmount = @sAmount
			if (@sAmount < 0 and @cartTotal + @sAmount < 0)
				set @applyAmount = case when @cartTotal < 0 then 0.0 else -@cartTotal end

			set @cartTotal = @cartTotal + @applyAmount

			insert into @discountsApplied
			(product_path, discount_order, discount_product_id, originating_product_id, product_student_id,
				eligible_for_entity_id, eligible_for_entity_type, 
				waiver_code, student_id, account_id, amount)
			values(@sPath, @sOrder, @sProduct, null, null, 0, null, @sWaiver, null, @sAccount, @applyAmount)

			set @sIdx = @sIdx + 1
		end

		declare @ret table (
			row_id int identity(1,1),
			product_id int,
			product_desc varchar(500),
		waiver_code varchar(50),
		amount decimal(18,6), 
		account_id int,
		is_deposit bit,
		student_id int
	)

	insert into @ret (product_id, product_desc, waiver_code, amount, account_id, student_id)	
	--select discount_product_id, p.Product_Sale_Description + coalesce(' for ' + orig_p.Product_Sale_Description, ''), waiver_code, amount, 
	--	coalesce(da.account_id, orig_p.default_revenue_account_id), student_id
	--from @discountsApplied da
	--inner join fin_products p on
	--  (da.discount_product_id = p.product_id)
	--left join fin_products orig_p on
	--  (da.originating_product_id = orig_p.product_id)
	--inner join @bestPath bp on 
	--   (product_path = path_num)
	select discount_product_id, p.Product_Sale_Description, waiver_code, sum(amount), 
		coalesce(da.account_id, orig_p.default_revenue_account_id), student_id
	from @discountsApplied da
	inner join fin_products p on
	  (da.discount_product_id = p.product_id)
	left join fin_products orig_p on
	  (da.originating_product_id = orig_p.product_id)
	inner join @bestPath bp on 
	   (product_path = path_num)
	group by discount_product_id, p.Product_Sale_Description, waiver_code, coalesce(da.account_id, orig_p.default_revenue_account_id), student_id


	-- Calculate deposits.  Amount is lesser of remaining product price or deposit amount.
	insert into @ret (product_id, product_desc, amount, account_id, is_deposit, student_id)	
	select product_id, coalesce(fin_products.Product_Sale_Description, '') + ' Deposit',
		case when @additionalDepositLocal = 1 then
			case when Product_Sale_Price + deposit_amount + coalesce(discount_amount, 0.0) < deposit_amount then 
				case when Product_Sale_Price + deposit_amount + coalesce(discount_amount, 0.0) < 0.0 then 0.0
				else Product_Sale_Price + deposit_amount + coalesce(discount_amount, 0.0) end
			else deposit_amount end
		else
			case when Product_Sale_Price + coalesce(discount_amount, 0.0) < deposit_amount then 
				case when Product_Sale_Price + coalesce(discount_amount, 0.0) < 0.0 then 0.0
				else Product_Sale_Price + coalesce(discount_amount, 0.0) end
			else deposit_amount end
		end,
		coalesce(deposit_account_id, default_revenue_account_id),
		1 is_deposit, ps.studentId
	from #productStudents ps
	inner join fin_products on
	  (ps.productId = fin_products.product_id)
	left join (
		select product_student_id, sum(amount)  as discount_amount
		from @discountsApplied da, @bestPath bp
		where product_path = path_num 
		group by product_student_id
	) d_discounts on
	  (d_discounts.product_student_id = ps.id)

	select coalesce(product_id, 0) product_id, coalesce(product_desc, '') product_desc, coalesce(waiver_code, '') waiver_code, 
		coalesce(round(amount, 2), 0.0) amount, convert(bit, coalesce(is_deposit, 0)) is_deposit, account_id,
		coalesce(student_id, 0) student_id
	from @ret
	order by amount desc
end
GO
