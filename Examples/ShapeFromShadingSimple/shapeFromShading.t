local USE_MASK_REFINE 			= true

local USE_DEPTH_CONSTRAINT 		= true
local USE_REGULARIZATION 		= true
local USE_SHADING_CONSTRAINT 	= true
local USE_TEMPORAL_CONSTRAINT 	= false
local USE_PRECONDITIONER 		= false

local USE_PRECOMPUTE = true
local USE_CRAPPY_SHADING_BOUNDARY = true
local USE_PROPER_REGULARIZATION_BOUNDARY  = true

local FLOAT_EPSILON = 0.000001
local DEPTH_DISCONTINUITY_THRE = 0.01

local IO = terralib.includec("stdio.h")

local P 	= opt.ProblemSpec()
local W,H 	= opt.Dim("W",0), opt.Dim("H",1)

-- See TerraSolverParameters
local w_p						= P:Param("w_p",float,0)-- Is initialized by the solver!
local w_s		 				= P:Param("w_s",float,1)-- Regularization weight
local w_r						= P:Param("w_r",float,2)-- Prior weight
local w_g						= P:Param("w_g",float,3)-- Shading weight

local weightShadingStart		= P:Param("weightShadingStart",float,4)-- Starting value for incremental relaxation
local weightShadingIncrement	= P:Param("weightShadingIncrement",float,5)-- Update factor

local weightBoundary			= P:Param("weightBoundary",float,6)-- Boundary weight

local f_x						= P:Param("f_x",float,7)
local f_y						= P:Param("f_y",float,8)
local u_x 						= P:Param("u_x",float,9)
local u_y 						= P:Param("u_y",float,10)
    
local offset = 10;
local deltaTransform = {}
for i=1,16 do
	deltaTransform[i] = P:Param("deltaTransform_" .. i .. "",float,offset+i)
end
offset = offset + 16

local L = {}
for i=1,9 do
	L[i] = P:Param("L_" .. i-1 .. "",float,offset+i)
end
offset = offset + 9
local nNonLinearIterations 	= P:Param("nNonLinearIterations",uint,offset+1) -- Steps of the non-linear solver	
local nLinIterations 		= P:Param("nLinIterations",uint,offset+2) -- Steps of the linear solver
local nPatchIterations 		= P:Param("nPatchIterations",uint,offset+3) -- Steps on linear step on block level


offset = offset + 4
local D 	= P:Unknown("X",float, {W,H},offset+0) -- Refined Depth
local D_i 	= P:Image("D_i",float, {W,H},offset+1) -- Depth input
local I 	= P:Image("I",float, {W,H},offset+2) -- Target Intensity
local D_p 	= P:Image("D_p",float, {W,H},offset+3) -- Previous Depth
local edgeMaskR 	= P:Image("edgeMaskR",uint8, {W,H},offset+4) -- Edge mask. 
local edgeMaskC 	= P:Image("edgeMaskC",uint8, {W,H},offset+5) -- Edge mask. 

local B_I
local B_I_dx0
local B_I_dx1
local B_I_dx2
if USE_PRECOMPUTE then
	B_I = P:Image("B_I", float, {W,H}, "alloc")
	B_I_dx0 = P:Image("B_I_dx0", float, {W,H}, "alloc")
	B_I_dx1 = P:Image("B_I_dx1", float, {W,H}, "alloc")
	B_I_dx2 = P:Image("B_I_dx2", float, {W,H}, "alloc")
	pguard = P:Image("pguard", float, {W,H}, "alloc")
end	

P:Stencil(2)

local F = {}
local WH = opt.toispace {W,H}
local TUnknownType = P:UnknownType():terratype()
local Index = WH:indextype()

local ScalarImageType = P:ImageType(float, WH):terratype()

local float3 = vector(float, 3)
local float4 = vector(float, 4)
local mat4   = vector(float, 16)

local terra make_float2(x : float, y : float)
	return vector(x,y)
end

local terra make_float3(x : float, y : float, z : float)
	return vector(x, y, z)
end

local terra make_float4(x : float, y : float, z : float, w : float)
	return vector(x, y, z, w)
end

local terra dot(v0 : float3, v1 : float3)
	return v0[0]*v1[0] + v0[1]*v1[1] + v0[2]*v1[2]
end

local terra sqMagnitude(v : float3) 
	return dot(v, v)
end

local terra IsValidPoint(d : float)
	return d > 0
end

local terra I(self : P:ParameterType(), idx : Index)
    -- This weird semi-blur was in the original code, so ported here.
	return self.I(idx(0,0))(0)*0.5f + 0.25f*(self.I(idx(-1,0))(0)+self.I(idx(0,-1))(0))
end

-- equation 8
local terra p(idx : Index, gi : int32, gj : int32, self : P:ParameterType()) 
    var d : float= self.X(idx)(0)
    return make_float3((([float](gi)-self.u_x)/self.f_x)*d, (([float](gj)-self.u_y)/self.f_y)*d, d)
end

-- equation 10
local terra n(idx : Index, gi : int32, gj : int32, self : P:ParameterType())
    --f_x good, f_y good

    var center, left, up = idx, idx(-1,0), idx(0,-1)

    var n_x = (self.X(up)(0) * (self.X(center)(0) - self.X(left)(0))) / self.f_y
    var n_y = (self.X(left)(0) * (self.X(center)(0) - self.X(up)(0))) / self.f_x
    var n_z = 	((n_x * (self.u_x - [float](gi))) / self.f_x) + 
    			((n_y * (self.u_y - [float](gj))) / self.f_y) - 
    			( (self.X(left)(0)*self.X(up)(0)) / (self.f_x*self.f_y))
	var lengthSquared = n_x*n_x + n_y*n_y + n_z*n_z
   
    var normal = make_float3(n_x, n_y, n_z)
    if lengthSquared > 0 then
    	normal = normal / opt.math.sqrt(lengthSquared)
    end
    return normal
end

local terra B(idx : Index, gi : int32, gj : int32, self : P:ParameterType())
	var normal = n(idx, gi, gj, self)
	var n_x : float = normal[0]
	var n_y : float = normal[1]
	var n_z : float = normal[2]

	var lighting = self.L_0 +
					 self.L_1*n_y + self.L_2*n_z + self.L_3*n_x  +
					 self.L_4*n_x*n_y + self.L_5*n_y*n_z + self.L_6*(-n_x*n_x - n_y*n_y + 2*n_z*n_z) + self.L_7*n_z*n_x + self.L_8*(n_x*n_x-n_y*n_y)

	return 1.0*lighting -- replace 1.0 with estimated albedo in slower version
end

local terra mat4_times_float4(M : mat4, v : float4)
	var result : float[4]
	escape
		for i=0,3 do
			emit quote 
				result[i] = M[i*4+0]*v[0] + M[i*4+1]*v[1] + M[i*4+2]*v[2] + M[i*4+3]*v[3]
			end
		end
    end
	return make_float4(result[0], result[1], result[2], result[3])
end

local terra estimate_normal_from_depth2(inPriorDepth : ScalarImageType, gidx : int, gidy : int, W : int, H : int, ax : float, ay : float, f_x : float, f_y : float)
	var x : float = 0.0f
	var y : float = 0.0f
	var z : float = 0.0f

	var d0 : float = inPriorDepth.data[gidy*W+gidx-1](0);
	var d1 : float = inPriorDepth.data[gidy*W+gidx](0);
	var d2 : float = inPriorDepth.data[(gidy-1)*W+gidx](0);

	if IsValidPoint(d0) and IsValidPoint(d1) and IsValidPoint(d2) then
		x = - d2*(d0-d1)/f_y;
		y = - d0*(d2-d1)/f_x;
		z = -ay*y - ax*x - d2*d0/f_x/f_y;			
		var an : float = opt.math.sqrt( x * x + y * y + z * z )
		if(an ~= 0.0f) then
			x = x / an; 
			y = y / an; 
			z = z / an;
		end
	end

	return vector(x,y,z)
end

local function create_vector(self,name, count)
	local names = {}
	for i=1,count do
		names[i] = `self.[name..i]
	end
	return `vector(names)
end

local terra prior_normal_from_previous_depth(d : float, gidx : int32, gidy : int32, self : P:ParameterType(), normal0 : &float3, normal1 : &float3, normal2 : &float3)

	var f_x : float = self.f_x
	var f_y : float = self.f_y
	var u_x : float = self.u_x
	var u_y : float = self.u_y
	var uf_x : float = 1.0f / f_x
	var uf_y : float = 1.0f / f_y
	var W = [W.size]
	var H = [H.size]
	
	--var deltaTransform : mat4 = vector(self.deltaTransform_1, self.deltaTransform_2, self.deltaTransform_3, self.deltaTransform_4, self.deltaTransform_5, self.deltaTransform_6, self.deltaTransform_7, self.deltaTransform_8, self.deltaTransform_9, self.deltaTransform_10, self.deltaTransform_11, self.deltaTransform_12, self.deltaTransform_13, self.deltaTransform_14, self.deltaTransform_15, self.deltaTransform_16)

    var deltaTransform : mat4 = [create_vector(self, "deltaTransform_", 16)]

	var position_prev : float4 = mat4_times_float4(deltaTransform, make_float4((gidx-u_x)*d/f_x, (gidy-u_y)*d/f_y,d,1.0f))

	if((not IsValidPoint(d)) or position_prev[3] ==0.0f) then
		@normal0 = make_float3(0.0f,0.0f,0.0f);
		@normal1 = make_float3(0.0f,0.0f,0.0f);
		@normal2 = make_float3(0.0f,0.0f,0.0f);
		return 	
	end

	var posx = [int](f_x*position_prev[0]/position_prev[2] + u_x +0.5f)
	var posy = [int](f_y*position_prev[1]/position_prev[2] + u_y +0.5f)

	if(posx<2 or posx>(W-3) or posy<2 or posy>(H-3)) then
		@normal0 = make_float3(0.0f,0.0f,0.0f)
		@normal1 = make_float3(0.0f,0.0f,0.0f)
		@normal2 = make_float3(0.0f,0.0f,0.0f)
		return 	
	end

	var ax : float = (posx-u_x)/f_x;
	var ay : float = (posy-u_y)/f_y;

	@normal0 = estimate_normal_from_depth2(self.D_p, posx, posy, W,H, ax, ay, f_x, f_y);
	@normal1 = estimate_normal_from_depth2(self.D_p, posx+1, posy, W, H, ax+uf_x, ay, f_x, f_y);
	@normal2 = estimate_normal_from_depth2(self.D_p, posx, posy+1, W, H,ax, ay+uf_y, f_x, f_y);

	return 
end

local terra calShading2depthGradHelper(idx : Index, posx : int, posy: int, self : P:ParameterType()) : float4
	var f_x : float = self.f_x
	var f_y : float = self.f_y
	var u_x : float = self.u_x
	var u_y : float = self.u_y

	var mid,left,up =idx,idx(-1,0),idx(0,-1)

	var d0 : float = self.X(left)(0);
	var d1 : float = self.X(mid)(0);
	var d2 : float = self.X(up)(0);
	
	if (IsValidPoint(d0)) and (IsValidPoint(d1)) and (IsValidPoint(d2)) then
		var greyval : float = (self.I(mid)(0)*0.5f + self.I(left)(0)*0.25f + self.I(up)(0)*0.25f)

		var ax : float = (posx-u_x)/f_x
		var ay : float = (posy-u_y)/f_y
		var an  : float,an2  : float

		var px  : float, py  : float, pz  : float
		px = d2*(d1-d0)/f_y;
		py = d0*(d1-d2)/f_x;
		pz =  - ax*px -ay*py - d2*d0/(f_x*f_y);			
		an2 = px*px+py*py+pz*pz;
		an = opt.math.sqrt(an2);
		if an==0 then
			return vector(0.0f, 0.0f, 0.0f, 0.0f);
		end

		px = px / an;
		py = py / an;
		pz = pz / an;


		var sh_callist0 : float = self.L_0;
		var sh_callist1 : float = py*self.L_1;
		var sh_callist2 : float = pz*self.L_2;
		var sh_callist3 : float = px*self.L_3;				
		var sh_callist4 : float = px * py * self.L_4;
		var sh_callist5 : float = py * pz * self.L_5;
		var sh_callist6 : float = ((-px*px-py*py+2*pz*pz))*self.L_6;
		var sh_callist7 : float = pz * px * self.L_7;
		var sh_callist8 : float = ( px * px - py * py )*self.L_8;


		-- normal changes wrt depth
		var gradx = 0.0f
		var grady = 0.0f
		var gradz = 0.0f

				
		gradx = gradx - sh_callist1*px
		gradx = gradx - sh_callist2*px
		gradx = gradx + (self.L_3-sh_callist3*px)
		gradx = gradx + py*self.L_4-sh_callist4*2*px
		gradx = gradx - sh_callist5*2*px
		gradx = gradx + (-2*px)*self.L_6-sh_callist6*2*px
		gradx = gradx + pz*self.L_7-sh_callist7*2*px
		gradx = gradx + 2*px*self.L_8-sh_callist8*2*px
		gradx = gradx / an
		

		grady = grady + (self.L_1-sh_callist1*py)
		grady = grady - sh_callist2*py
		grady = grady - sh_callist3*py
		grady = grady + px*self.L_4-sh_callist4*2*py
		grady = grady + pz*self.L_5-sh_callist5*2*py
		grady = grady + (-2*py)*self.L_6-sh_callist6*2*py
		grady = grady - sh_callist7*2*py
		grady = grady + (-2*py)*self.L_8-sh_callist8*2*py
		grady = grady / an
		
		gradz = gradz - sh_callist1*pz
		gradz = gradz + (self.L_2-sh_callist2*pz)
		gradz = gradz - sh_callist3*pz
		gradz = gradz - sh_callist4*2*pz
		gradz = gradz + py*self.L_5-sh_callist5*2*pz
		gradz = gradz + 4*pz*self.L_6-sh_callist6*2*pz
		gradz = gradz + px*self.L_7-sh_callist7*2*pz
		gradz = gradz - sh_callist8*2*pz
		gradz = gradz / an

		-- shading value stored in sh_callist0
		sh_callist0 = sh_callist0 + sh_callist1
		sh_callist0 = sh_callist0 + sh_callist2
		sh_callist0 = sh_callist0 + sh_callist3
		sh_callist0 = sh_callist0 + sh_callist4
		sh_callist0 = sh_callist0 + sh_callist5
		sh_callist0 = sh_callist0 + sh_callist6
		sh_callist0 = sh_callist0 + sh_callist7
		sh_callist0 = sh_callist0 + sh_callist8
		sh_callist0 = sh_callist0 - greyval;



		---- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- /
		---- 
		----                /|  2
		----              /  |
		----            /    |  
		----          0 -----|  1
		---- 
		---- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- /

		var grnds_0 : float, grnds_1 : float, grnds_2 : float

		grnds_0 = -d2/f_y;
		grnds_1 = (d1-d2)/f_x;
		grnds_2 = -ax*grnds_0 - ay*grnds_1-d2/(f_x*f_y);
		sh_callist1 = (gradx*grnds_0+grady*grnds_1+gradz*grnds_2);

		grnds_0 = d2/f_y;
		grnds_1 = d0/f_x;
		grnds_2 = -ax*grnds_0 - ay*grnds_1;
		sh_callist2 = (gradx*grnds_0+grady*grnds_1+gradz*grnds_2);

		grnds_0 = (d1-d0)/f_y;
		grnds_1 = -d0/f_x;
		grnds_2 = -ax*grnds_0 - ay*grnds_1 - d0/(f_x*f_y);
		sh_callist3 = (gradx*grnds_0+grady*grnds_1+gradz*grnds_2);


		return vector(sh_callist1, sh_callist2, sh_callist3, sh_callist0);
	else
		return vector(0.0f, 0.0f, 0.0f, 0.0f);
	end
end

local terra calShading2depthGrad(idx : Index, posx : int, posy: int, self : P:ParameterType()) : float4
	escape
		if USE_PRECOMPUTE then
			emit quote
				return make_float4(	self.B_I_dx0(idx)(0),
									self.B_I_dx1(idx)(0),
									self.B_I_dx2(idx)(0),
									self.B_I(idx)(0)) 
			end
		else
			emit quote
				return calShading2depthGradHelper(idx, posx, posy, self)
			end
		end
    end
end


local terra est_lap_init_3d_imp(idx : Index, self : P:ParameterType(), w0 : float, w1 : float, uf_x : float, uf_y : float, b_valid : &bool) : float3

	var retval_0 = 0.0f
	var retval_1 = 0.0f
	var retval_2 = 0.0f	
	var d  : float = self.X(idx)(0)
	var d0 : float = self.X(idx(-1,0))(0)
	var d1 : float = self.X(idx(1,0))(0)
	var d2 : float = self.X(idx(0,-1))(0)
	var d3 : float = self.X(idx(0,1))(0)

	if IsValidPoint(d) and IsValidPoint(d0) and IsValidPoint(d1) and IsValidPoint(d2) and IsValidPoint(d3)
		and opt.math.abs(d-d0) < [float](DEPTH_DISCONTINUITY_THRE) 
		and opt.math.abs(d-d1) < [float](DEPTH_DISCONTINUITY_THRE) 
		and opt.math.abs(d-d2) < [float](DEPTH_DISCONTINUITY_THRE) 
		and opt.math.abs(d-d3) < [float](DEPTH_DISCONTINUITY_THRE) then	
		retval_0 = d * w0 * 4;
		retval_1 = d * w1 * 4;
		retval_2 = d *4;

		retval_0 = retval_0 - d0*(w0 - uf_x);
		retval_1 = retval_1 - d0*w1;
		retval_2 = retval_2 - d0;

		retval_0 = retval_0 - d1*(w0+uf_x);
		retval_1 = retval_1 - d1*w1;
		retval_2 = retval_2 - d1;

		retval_0 = retval_0 - d2*w0;
		retval_1 = retval_1 - d2*(w1-uf_y);
		retval_2 = retval_2 - d2;

		retval_0 = retval_0 - d3*w0;
		retval_1 = retval_1 - d3*(w1+uf_y);
		retval_2 = retval_2 - d3;	
		
	else
		@b_valid = false
	end

	return vector(retval_0, retval_1, retval_2);
end


terra F.cost(idx : Index, self : P:ParameterType())
	var W = [W.size]
	var H = [H.size]
	var gi,gj = idx.d0,idx.d1

	var E_s_x : float = 0.0f
	var E_s_y : float = 0.0f
	var E_s_z : float = 0.0f


	var E_p : float = 0.0f
	var E_r_h : float = 0.0f 
	var E_r_v : float = 0.0f 
	var E_r_d : float = 0.0f 
	var E_g_v : float = 0.0f
	var E_g_h : float = 0.0f

	var mid,left,up,right,down  = idx(0,0), idx(-1,0), idx(0,-1), idx(1,0), idx(0,1)
	var leftUp,rightUp,leftDown = idx(-1,-1), idx(1,-1), idx(-1,1)

	var pointValid 				= mid:InBounds() and IsValidPoint(self.X(mid)(0))
    var leftValid 				= left:InBounds() and IsValidPoint(self.X(left)(0))
    var rightValid 				= right:InBounds() and IsValidPoint(self.X(right)(0))
    var upValid 				= up:InBounds() and IsValidPoint(self.X(up)(0))
    var downValid 				= down:InBounds() and IsValidPoint(self.X(down)(0))
	var leftAndCenterValid 		= pointValid and leftValid
    var rightAndCenterValid 	= pointValid and rightValid
	var upAndCenterValid   		= pointValid and upValid
    var downAndCenterValid      = pointValid and downValid
	var leftUpAndCenterValid 	= pointValid and leftUp:InBounds() and IsValidPoint(self.X(leftUp)(0))
	var rightUpValid 			= rightUp:InBounds() and IsValidPoint(self.X(rightUp)(0))
	var leftDownValid 			= leftDown:InBounds() and IsValidPoint(self.X(leftDown)(0))

	var horizontalLineValid 	= leftAndCenterValid and rightValid
	var verticalLineValid 		= upAndCenterValid and downValid
	var crossValid 				= horizontalLineValid and verticalLineValid

	if [USE_DEPTH_CONSTRAINT] and pointValid then 
		E_p = self.X(idx)(0) - self.D_i(idx)(0)
	end 

	var shadingDifference = 0.0f
	if [USE_SHADING_CONSTRAINT] then
		if (not [USE_MASK_REFINE]) or self.edgeMaskR(idx)(0) > 0.0f then
            if [USE_CRAPPY_SHADING_BOUNDARY] then
                if leftAndCenterValid and upValid then
                    E_g_h = B(idx,gi,gj,self) - I(self, idx)
                end
                if rightUpValid and rightAndCenterValid then
                    E_g_h = E_g_h - (B(right,gi+1,gj,self) - I(self, right))
                end
            else
                if (horizontalLineValid and rightUpValid and upAndCenterValid) then
                    E_g_h = B(idx,gi,gj,self) - B(right,gi+1,gj,self) - (I(self, idx) - I(self, right))
                end
            end
			
		end
	end

    if [USE_SHADING_CONSTRAINT] then
		if (not [USE_MASK_REFINE]) or self.edgeMaskC(idx)(0) > 0.0f then
            if [USE_CRAPPY_SHADING_BOUNDARY] then
                if leftAndCenterValid and upValid then
                    E_g_v = B(idx,gi,gj,self) - I(self, idx)
                end
                if leftDownValid and downAndCenterValid then
                    E_g_v = E_g_v - (B(down,gi,gj+1,self) - I(self, down))
                end
            else
                if (verticalLineValid and leftAndCenterValid and leftDownValid) then
                   E_g_v = B(idx,gi,gj,self) - B(down,gi,gj+1,self) - (I(self, idx) - I(self, down))
                end
            end
			
		end
	end

	if [USE_REGULARIZATION] and crossValid then
		var d = self.X(idx)(0)
		
         if opt.math.abs(d - self.X(idx(1,0))(0)) < [float](DEPTH_DISCONTINUITY_THRE) and 
			opt.math.abs(d - self.X(idx(-1,0))(0)) < [float](DEPTH_DISCONTINUITY_THRE) and 
			opt.math.abs(d - self.X(idx(0,1))(0)) < [float](DEPTH_DISCONTINUITY_THRE) and 
			opt.math.abs(d - self.X(idx(0,-1))(0)) < [float](DEPTH_DISCONTINUITY_THRE) then
         
				var E_s = (4.0f*p(idx,gi,gj,self) - (p(idx(-1,0),gi-1,gj, self) + p(idx(0,-1),gi,gj-1, self) + p(idx(1,0),gi+1,gj, self) + p(idx(0,1),gi,gj+1, self)))
				E_s_x = E_s[0]
				E_s_y = E_s[1]
				E_s_z = E_s[2]
		end
	end

	var n_p = make_float3(0.0f, 0.0f, 0.0f)
	if [USE_TEMPORAL_CONSTRAINT] then
		var temp1 : float3
		var temp2 : float3
		prior_normal_from_previous_depth(self.X(idx)(0), gi, gj, self, &n_p, &temp1, &temp2)
	end

	
	if [USE_TEMPORAL_CONSTRAINT] and leftAndCenterValid then
		E_r_h = dot(n_p, p(idx,gi,gj,self) - p(left,gi-1,gj,self))
	end

	if [USE_TEMPORAL_CONSTRAINT] and upAndCenterValid then
		E_r_v = dot(n_p, p(idx,gi,gj,self) - p(up,gi,gj-1,self))
	end

	if [USE_TEMPORAL_CONSTRAINT] and leftUpAndCenterValid then
		E_r_d = dot(n_p, p(idx,gi,gj,self) - p(leftUp,gi-1,gj-1,self))
	end

	var cost : float = self.w_s*E_s_x*E_s_x + self.w_s*E_s_y*E_s_y + self.w_s*E_s_z*E_s_z + self.w_p*E_p*E_p + self.w_g*E_g_h*E_g_h + self.w_g*E_g_v*E_g_v + self.w_r*E_r_h*E_r_h + self.w_r*E_r_v*E_r_v + self.w_r*E_r_d*E_r_d 

    
    return cost
	
end

---- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- 
----  evalMinusJTF
---- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- 

local terra evalMinusJTFDeviceLS_SFS_Shared_Mask_Prior(idx : Index, posx : int, posy : int, W : uint, H : int, self : P:ParameterType(),
														normal0 : float3, normal1 : float3, normal2 : float3, outPre : &float)
	var f_x : float = self.f_x
	var f_y : float = self.f_y
	var u_x : float = self.u_x
	var u_y : float = self.u_y
	var uf_x : float = 1.0f / f_x
	var uf_y : float = 1.0f / f_y


	var b = 0.0f 
	var p = 0.0f;

	-- Common stuff

	var targetDepth : float = self.D_i(idx)(0); 
	var validTarget : bool  = IsValidPoint(targetDepth);
	var XC : float 			= self.X(idx)(0);


		
	if validTarget then
		if posx>1 and posx<(W-5) and posy>1 and posy<(H-5) then
			
			var sum : float, tmpval : float
			var val0 : float, val1 : float, val2 : float
			var maskval : uint8 = 1			
			if [USE_SHADING_CONSTRAINT] then
				-- TODO: How do we break this out to amortize for AD
				val0 = calShading2depthGrad(idx, posx, posy, self)[1] --readValueFromCache2DLS_SFS(inGrady,tidy  ,tidx  );
				val1 = calShading2depthGrad(idx(1,0), posx + 1, posy, self)[0] --readValueFromCache2DLS_SFS(inGradx,tidy  ,tidx+1);
				val2 = calShading2depthGrad(idx(0,1), posx, posy + 1, self)[2] --readValueFromCache2DLS_SFS(inGradz,tidy+1,tidx  );
						
				var shadingDiff_0_m1 = calShading2depthGrad(idx(0,-1), posx+0, posy-1, self)[3]					
				var shadingDiff_1_m1 = calShading2depthGrad(idx(1,-1), posx+1, posy-1, self)[3]
				var shadingDiff_m1_0 = calShading2depthGrad(idx(-1,-0), posx-1, posy-0, self)[3]
				var shadingDiff_0_0	 = calShading2depthGrad(idx(0,0), posx,   posy,   self)[3]
				var shadingDiff_1_0	 = calShading2depthGrad(idx(1,0), posx+1, posy,   self)[3]
				var shadingDiff_2_0	 = calShading2depthGrad(idx(2,0), posx+2, posy,   self)[3]
				var shadingDiff_m1_1 = calShading2depthGrad(idx(-1,1), posx-1, posy+1, self)[3]
				var shadingDiff_0_1	 = calShading2depthGrad(idx(0,1), posx,   posy+1, self)[3]
				var shadingDiff_1_1	 = calShading2depthGrad(idx(1,1), posx+1, posy+1, self)[3]
				var shadingDiff_0_2	 = calShading2depthGrad(idx(0,2), posx,   posy+2, self)[3]
				escape
					
					if USE_MASK_REFINE then
						emit quote
							--calculating residue error
							--shading term
							--row edge constraint
							sum = 0.0f;	
							tmpval = 0.0f;			
							tmpval = -(shadingDiff_m1_0 - shadingDiff_0_0) -- edge 0				
							maskval = self.edgeMaskR(idx(-1,0))(0)
							sum = sum + tmpval*(-val0) * maskval --(posy, posx-1)*val0,(posy,posx)*(-val0)			
							tmpval = tmpval + val0*val0*maskval 

							tmpval = -(shadingDiff_0_0 - shadingDiff_1_0) -- edge 2				
							maskval = self.edgeMaskR(idx)(0)
							sum = sum + tmpval*(val0-val1) * maskval -- (posy,posx)*(val1-val0), (posy,posx+1)*(val0-val1)			
							tmpval	= tmpval + (val0-val1)*(val0-val1)* maskval

							tmpval = -(shadingDiff_1_0 - shadingDiff_2_0) -- edge 4				
							maskval = self.edgeMaskR(idx(1,0))(0)
							sum = sum + tmpval*(val1) * maskval -- (posy,posx+1)*(-val1), (posy,posx+2)*(val1)			
							tmpval	= tmpval + val1*val1* maskval

							tmpval = -(shadingDiff_m1_1 - shadingDiff_0_1) -- edge 5				
							maskval = self.edgeMaskR(idx(-1,1))(0)
							sum = sum + tmpval*(-val2) * maskval -- (posy+1,posx-1)*(val2),(posy+1,pox)*(-val2)			
							tmpval	= tmpval + val2*val2* maskval

							tmpval  = -(shadingDiff_0_1 - shadingDiff_1_1) -- edge 7				
							maskval = self.edgeMaskR(idx(0,1))(0)
							sum 	= sum + tmpval*val2 * maskval -- (posy+1,posx)*(-val2),(posy+1,posx+1)*(val2)
							tmpval	= tmpval + val2*val2 * maskval
										
							--column edge constraint			
							tmpval 	= -(shadingDiff_0_m1 - shadingDiff_0_0) -- edge 1
							maskval = self.edgeMaskC(idx(0,-1))(0)
							sum 	= sum + tmpval*(-val0) * maskval -- (posy-1,posx)*(val0),(posy,posx)*(-val0)			
							tmpval	= tmpval + val0*val0* maskval

							tmpval 	= -(shadingDiff_1_m1 - shadingDiff_1_0) --edge 3
							maskval = self.edgeMaskC(idx(1,-1))(0)
							sum 	= sum + tmpval*(-val1) * maskval --(posy-1,posx+1)*(val1),(posy,posx+1)*(-val1)			
							tmpval	= tmpval +  val1*val1* maskval

							tmpval 	= -(shadingDiff_0_0 - shadingDiff_0_1) --edge 6
							maskval = self.edgeMaskC(idx)(0)
							sum 	= sum + tmpval*(val0-val2) * maskval -- (posy,posx)*(val2-val0),(posy+1,posx)*(val0-val2)			
							tmpval	= tmpval +  (val0-val2)*(val0-val2)* maskval

							tmpval = -(shadingDiff_1_0 - shadingDiff_1_1) --edge 8
							maskval = self.edgeMaskC(idx(1,0))(0)
							sum = sum + tmpval*val1 * maskval -- (posy,posx+1)*(-val1),(posy+1,posx+1)*(val1)
							tmpval	= tmpval +  val1*val1* maskval

							tmpval 	= -(shadingDiff_0_1 - shadingDiff_0_2) --edge 9
							maskval = self.edgeMaskC(idx(0,1))(0)
							sum 	= sum + tmpval*val2 * maskval --(posy+1,posx)*(-val2),(posy+2,posx)*(val2)
							tmpval	= tmpval + val2*val2* maskval

							b = b + sum * self.w_g
							p = p + tmpval * self.w_g -- shading constraint
						end
					else
						emit quote
							tmpval = 0.0f
							tmpval = val0 * val0 * 2.0f
							tmpval = tmpval + (val0 - val1) * (val0 - val1)
							tmpval = tmpval + (val0 - val2) * (val0 - val2)
							tmpval = tmpval + val1 * val1 * 3.0f
							tmpval = tmpval + val2 * val2 * 3.0f
							p = p + tmpval * self.w_g -- shading constraint

							-- val0, val1, val2 all within a few hundreths of each other between cuda and this version.
							-- their values are also in the range of 100s, so thats 5ish decimal places of precision.
							-- this quickly deteriorates when they are combined into p... to being off by 30,000ish when
							-- values are ~4million


							sum = 0.0f
							sum = sum + val0 * shadingDiff_0_m1					
							sum = sum + val1 * shadingDiff_1_m1						
							sum = sum + val0 * shadingDiff_m1_0				
							sum = sum + (-val0+val1-val0-val0+val2-val0) * shadingDiff_0_0				
							sum = sum + (val0-val1-val1-val1-val1) * shadingDiff_1_0							
							sum = sum + val1 * shadingDiff_2_0			
							sum = sum + val2 * shadingDiff_m1_1				
							sum = sum +  (-val2-val2+val0-val2-val2) * shadingDiff_0_1				
							sum = sum + (val2+val1) * shadingDiff_1_1			
							sum = sum + val2  * shadingDiff_0_2	
							
							b = b + sum * self.w_g
						end
					end					
				end

			end
			---- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- 
			----                    smoothness term
			---- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- /
			var d : float
			var b_valid = true
			if [USE_REGULARIZATION] then
				val0 = (posx - u_x)/f_x	
				val1 = (posy - u_y)/f_y				

				-- smoothness term							
				var  lapval : float3 = est_lap_init_3d_imp(idx,self,val0,val1,uf_x,uf_y,&b_valid);
				sum =  0.0f;
				sum = sum + lapval[0]*val0*(-4.0f);
				sum = sum + lapval[1]*val1*(-4.0f);
				sum = sum + lapval[2]*(-4.0f);
										
				lapval = est_lap_init_3d_imp(idx(-1,0),self,val0-uf_x,val1,uf_x,uf_y,&b_valid);
				sum = sum + lapval[0]*val0;
				sum = sum + lapval[1]*val1;
				sum = sum + lapval[2];
										
				lapval = est_lap_init_3d_imp(idx(1,0),self,val0+uf_x,val1,uf_x,uf_y,&b_valid);
				sum = sum + lapval[0]*val0;
				sum = sum + lapval[1]*val1;
				sum = sum + lapval[2];
										
				lapval = est_lap_init_3d_imp(idx(0,-1),self,val0,val1-uf_y,uf_x,uf_y,&b_valid);
				sum = sum + lapval[0]*val0
				sum = sum + lapval[1]*val1
				sum = sum + lapval[2]
										
				lapval = est_lap_init_3d_imp(idx(0,1),self,val0,val1+uf_y,uf_x,uf_y,&b_valid);
				sum = sum + lapval[0]*val0;
				sum = sum + lapval[1]*val1;
				sum = sum + lapval[2]
					
				if [USE_PROPER_REGULARIZATION_BOUNDARY] or b_valid then
					b = b + sum* self.w_s					
					tmpval = (val0 * val0 + val1 * val1 + 1)*(16+4);						
					p = p + tmpval * self.w_s --smoothness
				end
			end
			

			if [USE_DEPTH_CONSTRAINT]	then
				--position term 			
				p = p + self.w_p --position constraint			
				b = b - ((XC - targetDepth) * self.w_p);
			end



			---- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- 
			----                    prior term
			---- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- /
			if [USE_TEMPORAL_CONSTRAINT] then
				---- first: calculate the normal for PriorDepth

				sum = 0.0f;
				var ax = (posx-u_x)/f_x;
				var ay = (posy-u_y)/f_y;		
				
				tmpval = normal0[0] * ax + normal0[1] * ay + normal0[2] -- derative of prior energy wrt depth			
				p = p + tmpval * tmpval * 2  * self.w_r;

				d = self.X(idx(-1,0))(0)
				if(IsValidPoint(d)) then
					sum = sum - tmpval * ( tmpval * self.X(idx)(0) + ( -tmpval + normal0[0]/f_x) * d );
				end

				d = self.X(idx(0,-1))(0)
				if(IsValidPoint(d)) then
					sum = sum - tmpval * ( tmpval * self.X(idx)(0) + ( -tmpval + normal0[1]/f_y) * d );
				end

				tmpval = normal1[0] * ax + normal1[1] * ay + normal1[2] -- derative of prior energy wrt depth			
				p = p + tmpval * tmpval * self.w_r;
				d = self.X(idx(1,0))(0)
				if(IsValidPoint(d)) then
					sum = sum + tmpval * ( ( tmpval + normal1[0]/f_x) * d - tmpval * self.X(idx)(0))
				end

				tmpval = normal2[0] * ax + normal2[1] * ay + normal2[2] -- derative of prior energy wrt depth
				p = p + tmpval * tmpval * self.w_r;
				d = self.X(idx(0,1))(0)
				if(IsValidPoint(d)) then
					sum = sum + tmpval * ( ( tmpval + normal2[1]/f_y) * d - tmpval * self.X(idx)(0))
				end

				b = b + sum  * self.w_r;
			end
			
		end
	end


	if p > [float](FLOAT_EPSILON) then
		@outPre = 1.0f/p
	else 
		@outPre = 1.0f
	end

	return b;
end


terra F.evalJTF(idx : Index, self : P:ParameterType())
		
	var Pre     : float
	var normal0 : float3
	var normal1 : float3
	var normal2 : float3

	prior_normal_from_previous_depth(self.X(idx)(0), idx.d0, idx.d1, self, &normal0, &normal1, &normal2);
	
	--__syncthreads()

	---- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- 
	----  Initialize linear patch systems
	---- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- 

	-- Negative gradient
	var negGradient : float = evalMinusJTFDeviceLS_SFS_Shared_Mask_Prior(idx, idx.d0, idx.d1, [W.size], [H.size], self, normal0,normal1,normal2, &Pre); 
	if not [USE_PRECONDITIONER] then
		Pre = 1.0f
	end

	return -2.0f*negGradient, Pre
end

local terra add_mul_inp_grad_ls_bsp(self : P:ParameterType(), pImage : TUnknownType, idx : Index, posx : int, posy : int)
	var gradient = calShading2depthGrad(idx, posx, posy, self)
	return pImage(idx(-1,0))(0)	* gradient[0]
		  + pImage(idx)(0)	* gradient[1]
	   	  + pImage(idx(0,-1))(0)	* gradient[2]
end

local terra est_lap_3d_bsp_imp(pImage : TUnknownType, idx : Index, w0 : float, w1 : float, uf_x : float, uf_y : float)
	
	
	var d  : float = pImage(idx)(0)
	var d0 : float = pImage(idx(-1,0))(0)
	var d1 : float = pImage(idx(1,0))(0)
	var d2 : float = pImage(idx(0,-1))(0)
	var d3 : float = pImage(idx(0,1))(0)
	
	var x : float = ( d * 4 * w0 - d0 * (w0 - uf_x) - d1 * (w0 + uf_x)	- d2 * w0 - d3 * w0);
	var y : float = ( d * 4 * w1 - d0 * w1 - d1 * w1 - d2 * (w1 - uf_y) - d3 * (w1 + uf_y));
	var z : float = ( d * 4 - d0 - d1 - d2 - d3);
	return vector(x,y,z);
end

local terra est_lap_3d_bsp_imp_with_guard(self : P:ParameterType(), pImage : TUnknownType, idx : Index, w0 : float, w1 : float, uf_x : float, uf_y : float, b_valid : &bool)
	
	var retval_0 = 0.0f
	var retval_1 = 0.0f
	var retval_2 = 0.0f	
	
	if self.pguard:get(idx)(0) == 1.f then	
		var p  : float = pImage(idx)(0)
		var p0 : float = pImage(idx(-1,0))(0)
		var p1 : float = pImage(idx(1,0))(0)
		var p2 : float = pImage(idx(0,-1))(0)
		var p3 : float = pImage(idx(0,1))(0)
		
		retval_0 = ( p * 4 * w0 - p0 * (w0 - uf_x) - p1 * (w0 + uf_x)	- p2 * w0 - p3 * w0);
		retval_1 = ( p * 4 * w1 - p0 * w1 - p1 * w1 - p2 * (w1 - uf_y) - p3 * (w1 + uf_y));
		retval_2 = ( p * 4 - p0 - p1 - p2 - p3);
	else
		@b_valid = false
	end
	return vector(retval_0,retval_1,retval_2);
end

local terra applyJTJDeviceLS_SFS_Shared_BSP_Mask_Prior(idx : Index, posx : int, posy : int, W : uint, H : int, self : P:ParameterType(), pImage : TUnknownType,
														normal0 : float3, normal1 : float3, normal2 : float3)

	var f_x : float = self.f_x
	var f_y : float = self.f_y
	var u_x : float = self.u_x
	var u_y : float = self.u_y
	var uf_x : float = 1.0f / f_x
	var uf_y : float = 1.0f / f_y

	var b = 0.0f

	var targetDepth : float = self.D_i(idx)(0) 
	var validTarget : bool 	= IsValidPoint(targetDepth);
	var PC : float  		= pImage(idx)(0)
		
	if validTarget then
		if (posx>1) and (posx<(W-5)) and (posy>1) and (posy<(H-5)) then
			var sum : float = 0.0f;
			var tmpval : float = 0.0f;			

			var val0 : float, val1 : float, val2 : float

			if [USE_SHADING_CONSTRAINT] then
				-- TODO: How do we break this out to amortize for AD
				val0 = calShading2depthGrad(idx(0,0), posx, posy, self)[1] --readV
				val1 = calShading2depthGrad(idx(1,0), posx + 1, posy, self)[0]
				val2 = calShading2depthGrad(idx(0,1), posx, posy + 1, self)[2]

				var grad_0_m1 = calShading2depthGrad(idx(0,-1), posx+0, posy-1, self)					
				var grad_1_m1 = calShading2depthGrad(idx(1,-1), posx+1, posy-1, self)
				var grad_m1_0 = calShading2depthGrad(idx(-1,-0), posx-1, posy-0, self)
				var grad_0_0  = calShading2depthGrad(idx(0,0), posx,   posy,   self)
				var grad_1_0  = calShading2depthGrad(idx(1,0), posx+1, posy,   self)
				var grad_2_0  = calShading2depthGrad(idx(2,0), posx+2, posy,   self)
				var grad_m1_1 = calShading2depthGrad(idx(-1,1), posx-1, posy+1, self)
				var grad_0_1  = calShading2depthGrad(idx(0,1), posx,   posy+1, self)
				var grad_1_1  = calShading2depthGrad(idx(1,1), posx+1, posy+1, self)
				var grad_0_2  = calShading2depthGrad(idx(0,2), posx,   posy+2, self)

				escape
					
					if USE_MASK_REFINE then
						emit quote
							--pImage(idx)(0) * grad_0_0[0] // Doesn't do anything?!

							-- the following is the adding of the relative edge constraints to the sum
							-- -val0, edge 0			
							tmpval  = pImage(idx(-2,0))(0) *  grad_m1_0[0];
							tmpval = tmpval + pImage(idx(-1,0))(0) * (grad_m1_0[1] - grad_0_0[0]);
							tmpval = tmpval + pImage(idx(-1,-1))(0) *  grad_m1_0[2];
							tmpval = tmpval - pImage(idx)(0) *  grad_0_0[1];
							tmpval = tmpval - pImage(idx(0,-1))(0) *  grad_0_0[2];			
							sum = sum + (-val0) * tmpval  * self.edgeMaskR(idx(-1,0))(0)
							
							-- -val0, edge 1
							tmpval  = pImage(idx(-1,-1))(0) *  grad_0_m1[0];
							tmpval = tmpval + pImage(idx(0,-1))(0) * (grad_0_m1[1] - grad_0_0[2]);
							tmpval = tmpval + pImage(idx(0,-2))(0) *  grad_0_m1[2];
							tmpval = tmpval - pImage(idx(-1,0))(0) *  grad_0_0[0];
							tmpval = tmpval - pImage(idx)(0) *  grad_0_0[1];		
							sum = sum + (-val0) * tmpval  * self.edgeMaskC(idx(0,-1))(0)

							-- val0-val1, edge 2
							tmpval  = pImage(idx(-1,0))(0) *  grad_0_0[0];
							tmpval = tmpval + pImage(idx)(0) * (grad_0_0[1] - grad_1_0[0]);
							tmpval = tmpval + pImage(idx(0,-1))(0) *  grad_0_0[2];
							tmpval = tmpval - pImage(idx(1,0))(0) *  grad_1_0[1];
							tmpval = tmpval - pImage(idx(1,-1))(0) *  grad_1_0[2];		
							sum = sum + (val0-val1) * tmpval * self.edgeMaskR(idx)(0)

							-- -val1, edge 3			
							tmpval  = pImage(idx(0,-1))(0) *  grad_1_m1[0];
							tmpval = tmpval + pImage(idx(1,-1))(0) * (grad_1_m1[1] - grad_1_0[2]);
							tmpval = tmpval + pImage(idx(1,-2))(0) *  grad_1_m1[2];
							tmpval = tmpval - pImage(idx)(0) *  grad_1_0[0];
							tmpval = tmpval - pImage(idx(1,0))(0) *  grad_1_0[1];		
							sum = sum + (-val1) * tmpval	* self.edgeMaskC(idx(1,-1))(0)

							-- val1, edge 4
							tmpval  = pImage(idx)(0) *  grad_1_0[0];
							tmpval = tmpval + pImage(idx(1,0))(0) * (grad_1_0[1] - grad_2_0[0]);
							tmpval = tmpval + pImage(idx(1,-1))(0) *  grad_1_0[2];
							tmpval = tmpval - pImage(idx(2,0))(0) *  grad_2_0[1];
							tmpval = tmpval - pImage(idx(2,-1))(0) *  grad_2_0[2];		
							sum = sum + (val1) * tmpval * self.edgeMaskR(idx(1,0))(0)

							-- -val2, edge 5			
							tmpval  = pImage(idx(-2,1))(0) *  grad_m1_1[0];
							tmpval = tmpval + pImage(idx(-1,1))(0) * (grad_m1_1[1] - grad_0_1[0]);
							tmpval = tmpval + pImage(idx(-1,0))(0) *  grad_m1_1[2];
							tmpval = tmpval - pImage(idx(0,1))(0) *  grad_0_1[1];
							tmpval = tmpval - pImage(idx)(0) *  grad_0_1[2];		
							sum = sum + (-val2) * tmpval * self.edgeMaskR(idx(-1,1))(0)
							
							-- val0-val2, edge 6
							tmpval  = pImage(idx(-1,0))(0) *  grad_0_0[0];
							tmpval = tmpval + pImage(idx)(0) * (grad_0_0[1] - grad_0_1[2]);
							tmpval = tmpval + pImage(idx(0,-1))(0) *  grad_0_0[2];
							tmpval = tmpval - pImage(idx(-1,1))(0) *  grad_0_1[0];
							tmpval = tmpval - pImage(idx(0,1))(0) *  grad_0_1[1];		
							sum = sum + (val0-val2) * tmpval * self.edgeMaskC(idx)(0)

							-- val2, edge 7
							tmpval  = pImage(idx(-1,1))(0) *  grad_0_1[0];
							tmpval = tmpval + pImage(idx(0,1))(0) * (grad_0_1[1] - grad_1_1[0]);
							tmpval = tmpval + pImage(idx)(0) *  grad_0_1[2];
							tmpval = tmpval - pImage(idx(1,1))(0) *  grad_1_1[1];
							tmpval = tmpval - pImage(idx(1,0))(0) *  grad_1_1[2];		
							sum = sum + val2 * tmpval * self.edgeMaskR(idx(0,1))(0)

							-- val1, edge 8
							tmpval  = pImage(idx)(0) *  grad_1_0[0];
							tmpval = tmpval + pImage(idx(1,0))(0) * (grad_1_0[1] - grad_1_1[2]);
							tmpval = tmpval + pImage(idx(1,-1))(0) *  grad_1_0[2];
							tmpval = tmpval - pImage(idx(0,1))(0) *  grad_1_1[0];
							tmpval = tmpval - pImage(idx(1,1))(0) *  grad_1_1[1];		
							sum = sum + val1 * tmpval * self.edgeMaskC(idx(1,0))(0)

							-- val2, edge 9
							tmpval  = pImage(idx(-1,1))(0) *  grad_0_1[0];
							tmpval = tmpval + pImage(idx(0,1))(0) * (grad_0_1[1] - grad_0_2[2]);
							tmpval = tmpval + pImage(idx)(0) *  grad_0_1[2];
							tmpval = tmpval - pImage(idx(-1,2))(0) *  grad_0_2[0];
							tmpval = tmpval - pImage(idx(0,2))(0) *  grad_0_2[1];		
							sum = sum + val2 * tmpval * self.edgeMaskC(idx(0,1))(0)

							b = b + sum * self.w_g
						end

					else
						emit quote										
							sum = sum + (val1*4.0f-val0) * 		add_mul_inp_grad_ls_bsp(self, pImage, idx(1,0)   , posx+1, posy)-- mulitplication of grad with inP needs to consid			
							sum = sum + (val2*4.0f-val0) * 		add_mul_inp_grad_ls_bsp(self, pImage, idx(0,1) , posx,   posy+1)							
							sum = sum + (val0*4.0f-val1-val2) * add_mul_inp_grad_ls_bsp(self, pImage, idx(0,0)   , posx,   posy)				
							sum = sum + (-val2-val1) * 			add_mul_inp_grad_ls_bsp(self, pImage, idx(1,1) , posx+1, posy+1) 					
							sum = sum + (-val0) *  				add_mul_inp_grad_ls_bsp(self, pImage, idx(-1,0)   , posx-1, posy)							
							sum = sum + (-val1) *  				add_mul_inp_grad_ls_bsp(self, pImage, idx(2,0), posx+2, posy)						
							sum = sum + (-val0) *  				add_mul_inp_grad_ls_bsp(self, pImage, idx(0,-1) , posx,   posy-1)		
							sum = sum + (-val1) *  				add_mul_inp_grad_ls_bsp(self, pImage, idx(1,-1) , posx+1, posy-1)			
							sum = sum + (-val2) *  				add_mul_inp_grad_ls_bsp(self, pImage, idx(-1,1) , posx-1, posy+1)				
							sum = sum + (-val2) *  				add_mul_inp_grad_ls_bsp(self, pImage, idx(0,2) , posx,   posy+2)
							b = b + sum * self.w_g
						end
					end
				end
			end
			
						
			-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- 
			--                   Smoothness Term
			-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- /
				
			if [USE_REGULARIZATION] then

				sum = 0.0f
				val0 = (posx - u_x)/f_x
				val1 = (posy - u_y)/f_y

				if [USE_PROPER_REGULARIZATION_BOUNDARY] then 

					var b_valid = true

					var lapval : float3 = est_lap_3d_bsp_imp_with_guard(self,pImage,idx,val0,val1,uf_x,uf_y, &b_valid)			
					sum = sum + lapval[0]*val0*(4.0f)
					sum = sum + lapval[1]*val1*(4.0f)
					sum = sum + lapval[2]*(4.0f)

					lapval = est_lap_3d_bsp_imp_with_guard(self, pImage,idx(-1,0),val0-uf_x,val1,uf_x,uf_y, &b_valid)
					sum = sum - lapval[0]*val0
					sum = sum - lapval[1]*val1
					sum = sum - lapval[2]
								
					lapval = est_lap_3d_bsp_imp_with_guard(self, pImage,idx(1,0),val0+uf_x,val1,uf_x,uf_y, &b_valid)
					sum = sum - lapval[0]*val0
					sum = sum - lapval[1]*val1
					sum = sum - lapval[2]
								
					lapval = est_lap_3d_bsp_imp_with_guard(self, pImage,idx(0,-1),val0,val1-uf_y,uf_x,uf_y, &b_valid)
					sum = sum - lapval[0]*val0
					sum = sum - lapval[1]*val1
					sum = sum - lapval[2]
							
					lapval = est_lap_3d_bsp_imp_with_guard(self, pImage,idx(0,1),val0,val1+uf_y,uf_x,uf_y, &b_valid)
					sum = sum - lapval[0]*val0
					sum = sum - lapval[1]*val1
					sum = sum - lapval[2]

					-- always add
					b = b + sum*self.w_s
				else
					var lapval : float3 = est_lap_3d_bsp_imp(pImage,idx,val0,val1,uf_x,uf_y)			
					sum = sum + lapval[0]*val0*(4.0f)
					sum = sum + lapval[1]*val1*(4.0f)
					sum = sum + lapval[2]*(4.0f)
								
					lapval = est_lap_3d_bsp_imp(pImage,idx(-1,0),val0-uf_x,val1,uf_x,uf_y)
					sum = sum - lapval[0]*val0
					sum = sum - lapval[1]*val1
					sum = sum - lapval[2]
								
					lapval = est_lap_3d_bsp_imp(pImage,idx(1,0),val0+uf_x,val1,uf_x,uf_y)
					sum = sum - lapval[0]*val0
					sum = sum - lapval[1]*val1
					sum = sum - lapval[2]
								
					lapval = est_lap_3d_bsp_imp(pImage,idx(0,-1),val0,val1-uf_y,uf_x,uf_y)
					sum = sum - lapval[0]*val0
					sum = sum - lapval[1]*val1
					sum = sum - lapval[2]
								
					lapval = est_lap_3d_bsp_imp(pImage,idx(0,1),val0,val1+uf_y,uf_x,uf_y)
					sum = sum - lapval[0]*val0
					sum = sum - lapval[1]*val1
					sum = sum - lapval[2]

					b = b + sum*self.w_s
				end

				
			end

			-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- 
			--                   Position Term
			-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- /		
			if [USE_DEPTH_CONSTRAINT] then
				b = b + PC * self.w_p
			end


			-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- 
			--                    prior term
			-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- /			

			if [USE_TEMPORAL_CONSTRAINT] then
				sum = 0.0f
				var ax : float = (posx-u_x)/f_x
				var ay : float = (posy-u_y)/f_y;		
				tmpval = normal0[0] * ax + normal0[1] * ay + normal0[2] --  derative of prior energy wrt depth			
				sum = sum + tmpval * ( tmpval * pImage(idx)(0) + ( -tmpval + normal0[0]/f_x) * pImage(idx(-1,0))(0) )
				sum = sum + tmpval * ( tmpval * pImage(idx)(0) + ( -tmpval + normal0[1]/f_y) * pImage(idx(0,-1))(0) )
							
				tmpval = normal1[0] * ax + normal1[1] * ay + normal1[2] ;--  derative of prior energy wrt depth			
				sum = sum + -tmpval * ( ( tmpval + normal1[0]/f_x) * pImage(idx(1,0))(0) - tmpval * pImage(idx)(0))
							
				tmpval = normal2[0] * ax + normal2[1] * ay + normal2[2] ;--  derative of prior energy wrt depth			
				sum = sum + -tmpval * ( ( tmpval + normal2[1]/f_y) * pImage(idx(0,1))(0) - tmpval * pImage(idx)(0))

				b = b + sum * self.w_r
			end
		end
	end		
	
		
	
	return b;
end


-- eval 2*JtJ (note that we keep the '2' to make it consistent with the gradient
terra F.applyJTJ(idx : Index, self : P:ParameterType(), pImage : TUnknownType)
	var W : int = [W.size]
	var H : int = [H.size]

	var normal0 : float3
	var normal1 : float3
	var normal2 : float3

	prior_normal_from_previous_depth(self.X(idx)(0), idx.d0, idx.d1, self, &normal0, &normal1, &normal2)
	
	--__syncthreads()

 	var JTJ: float = applyJTJDeviceLS_SFS_Shared_BSP_Mask_Prior(idx, idx.d0, idx.d1, W, H, self, pImage, normal0, normal1, normal2)
	return 2.0*JTJ
end

if USE_PRECOMPUTE then
terra F.precompute(idx : Index, self : P:ParameterType())

	var temp = calShading2depthGradHelper(idx, idx.d0, idx.d1, self)
	self.B_I_dx0(idx) 	= temp[0]
	self.B_I_dx1(idx) 	= temp[1]
	self.B_I_dx2(idx) 	= temp[2]
	self.B_I(idx) 		= temp[3]
	var d  : float = self.X(idx)(0)
	var d0 : float = self.X(idx(-1,0))(0)
	var d1 : float = self.X(idx(1,0))(0)
	var d2 : float = self.X(idx(0,-1))(0)
	var d3 : float = self.X(idx(0,1))(0)
	var guard = terralib.select(IsValidPoint(d) and IsValidPoint(d0) and IsValidPoint(d1) and IsValidPoint(d2) and IsValidPoint(d3)
		and opt.math.abs(d-d0) < [float](DEPTH_DISCONTINUITY_THRE) 
		and opt.math.abs(d-d1) < [float](DEPTH_DISCONTINUITY_THRE) 
		and opt.math.abs(d-d2) < [float](DEPTH_DISCONTINUITY_THRE) 
		and opt.math.abs(d-d3) < [float](DEPTH_DISCONTINUITY_THRE),1.f,0.f)
	self.pguard(idx) = guard
end

end
P:Functions(WH,F)
return P